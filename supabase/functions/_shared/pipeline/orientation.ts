// Port of SmoooothKit SOTelemetry/VehicleOrientationEstimator.swift.
//
// The anchored-window logic in `ingestGPS` replicates the Swift `defer`
// exactly: once the span check `span >= accelerationWindowSeconds` passes,
// the anchor is advanced and pending samples discarded at scope exit — even
// when the dv/dt, up-axis, or yaw-rate guards reject the window. Implemented
// with try/finally.

import {
  v3add,
  v3cross,
  v3dot,
  v3neg,
  v3norm,
  v3normalized,
  v3scaled,
  v3sub,
  Vector3,
  VECTOR3_ZERO,
} from "./geo.ts";
import type { GPSSample, IMUSample, VehicleFrameSample } from "./types.ts";

/** Tunable thresholds for the orientation estimator (spec §19). */
export interface OrientationConfig {
  gravityTimeConstantSeconds: number;
  maxGravityDeviationG: number;
  quasiStaticDebounceSeconds: number;
  minStationaryDurationSeconds: number;
  minAccelerationMps2: number;
  accelerationWindowSeconds: number;
  maxYawRateRadPerSec: number;
  maxGPSGapSeconds: number;
  minForwardEvidenceGSeconds: number;
  evidenceSaturationGSeconds: number;
  minConsistencyRatio: number;
}

/** Mirrors Swift `OrientationConfig.default`. */
export const DEFAULT_ORIENTATION_CONFIG: OrientationConfig = {
  gravityTimeConstantSeconds: 0.5,
  maxGravityDeviationG: 0.02,
  quasiStaticDebounceSeconds: 0.05,
  minStationaryDurationSeconds: 1.0,
  minAccelerationMps2: 0.8,
  accelerationWindowSeconds: 0.8,
  maxYawRateRadPerSec: 0.15,
  maxGPSGapSeconds: 3.0,
  minForwardEvidenceGSeconds: 0.5,
  evidenceSaturationGSeconds: 1.5,
  minConsistencyRatio: 0.8,
};

/**
 * A converged device→vehicle orientation: the vehicle's forward/right/up
 * axes expressed as orthonormal unit vectors in the *device* frame.
 */
export class VehicleOrientationEstimate {
  constructor(
    readonly forwardDevice: Vector3,
    readonly rightDevice: Vector3,
    readonly upDevice: Vector3,
    readonly confidence: number,
  ) {}

  /** Transforms one device-frame inertial sample into the vehicle frame. */
  transform(imu: IMUSample): VehicleFrameSample {
    const reading: Vector3 = { x: imu.accelX, y: imu.accelY, z: imu.accelZ };
    const gyro: Vector3 = { x: imu.gyroX, y: imu.gyroY, z: imu.gyroZ };
    const trueAcceleration = v3add(reading, this.upDevice);
    return {
      timestamp: imu.timestamp,
      longitudinal: v3dot(trueAcceleration, this.forwardDevice),
      lateral: v3dot(trueAcceleration, this.rightDevice),
      vertical: v3dot(trueAcceleration, this.upDevice),
      yawRate: v3dot(gyro, this.upDevice),
    };
  }
}

interface PendingSample {
  timestamp: number;
  dt: number;
  trueAcceleration: Vector3;
  gyro: Vector3;
}

/**
 * Recovers the vehicle's axes from a phone mounted at an arbitrary, unknown
 * orientation (spec §19). Feed interleaved IMU and GPS samples in timestamp
 * order.
 */
export class VehicleOrientationEstimator {
  private readonly config: OrientationConfig;

  /** EMA of the raw accelerometer reading; points toward the earth. */
  private gravityEMA: Vector3 | null = null;
  private lastIMUTimestamp: number | null = null;
  /** Consecutive quasi-static time ending at the latest IMU sample. */
  private staticStreakSeconds = 0;
  /** Total quasi-static time that actually updated the gravity EMA. */
  private quasiStaticSeconds = 0;

  private pending: PendingSample[] = [];
  /** Start of the current acceleration window (windows never overlap). */
  private anchorFix: { timestamp: number; speedMps: number } | null = null;
  /** Vector sum of sign(dv/dt)-corrected horizontal acceleration, g·s. */
  private accumulatedForward: Vector3 = VECTOR3_ZERO;
  /** Scalar sum of horizontal acceleration norms, g·s. */
  private totalEvidenceGSeconds = 0;

  constructor(config: OrientationConfig = DEFAULT_ORIENTATION_CONFIG) {
    this.config = config;
  }

  /** Ingests one device-frame inertial sample. */
  ingestIMU(imu: IMUSample): void {
    const reading: Vector3 = { x: imu.accelX, y: imu.accelY, z: imu.accelZ };
    let dt: number;
    if (this.lastIMUTimestamp !== null) {
      dt = Math.max(0, imu.timestamp - this.lastIMUTimestamp);
      this.lastIMUTimestamp = Math.max(this.lastIMUTimestamp, imu.timestamp);
    } else {
      dt = 0;
      this.lastIMUTimestamp = imu.timestamp;
    }

    if (Math.abs(v3norm(reading) - 1) <= this.config.maxGravityDeviationG) {
      this.staticStreakSeconds += dt;
      if (this.gravityEMA !== null) {
        if (
          this.staticStreakSeconds >= this.config.quasiStaticDebounceSeconds
        ) {
          const alpha = this.smoothingFactor(dt);
          this.gravityEMA = v3add(
            this.gravityEMA,
            v3scaled(v3sub(reading, this.gravityEMA), alpha),
          );
          this.quasiStaticSeconds += dt;
        }
      } else {
        this.gravityEMA = reading;
      }
    } else {
      this.staticStreakSeconds = 0;
    }

    if (!this.isGravitySettled() || this.gravityEMA === null) return;
    this.pending.push({
      timestamp: imu.timestamp,
      dt,
      trueAcceleration: v3sub(reading, this.gravityEMA),
      gyro: { x: imu.gyroX, y: imu.gyroY, z: imu.gyroZ },
    });
    // Samples older than any trustable GPS window can never be scored.
    const horizon = imu.timestamp - this.config.maxGPSGapSeconds;
    this.pending = this.pending.filter((p) => !(p.timestamp < horizon));
  }

  /**
   * Ingests one GPS fix. Fixes with a negative horizontalAccuracy or a
   * missing/negative speed are ignored.
   */
  ingestGPS(gps: GPSSample): void {
    if (!(gps.horizontalAccuracy >= 0)) return;
    const speed = gps.speed;
    if (speed === null || !(speed >= 0)) return;

    const anchor = this.anchorFix;
    if (anchor === null) {
      this.anchorFix = { timestamp: gps.timestamp, speedMps: speed };
      this.discardPending(gps.timestamp);
      return;
    }
    const span = gps.timestamp - anchor.timestamp;
    if (!(span > 0)) return; // out-of-order or duplicate fix
    if (span > this.config.maxGPSGapSeconds) {
      // Stream gapped out; restart the window here.
      this.anchorFix = { timestamp: gps.timestamp, speedMps: speed };
      this.discardPending(gps.timestamp);
      return;
    }
    // Keep accumulating until the window is long enough for dv/dt to rise
    // above per-fix speed noise.
    if (!(span >= this.config.accelerationWindowSeconds)) return;

    // Swift `defer`: from here on the anchor advances and pending samples are
    // discarded at scope exit no matter which guard rejects the window.
    try {
      const dvdt = (speed - anchor.speedMps) / span;
      if (!(Math.abs(dvdt) >= this.config.minAccelerationMps2)) return;
      const up = this.upFromGravity();
      if (up === null) return;

      const window = this.pending.filter(
        (p) => p.timestamp > anchor.timestamp && p.timestamp <= gps.timestamp,
      );
      if (window.length === 0) return;
      if (
        !window.every(
          (s) => Math.abs(v3dot(s.gyro, up)) <= this.config.maxYawRateRadPerSec,
        )
      ) {
        return;
      }

      const sign = dvdt >= 0 ? 1 : -1;
      for (const sample of window) {
        if (!(sample.dt > 0)) continue;
        const vertical = v3scaled(up, v3dot(sample.trueAcceleration, up));
        const horizontal = v3sub(sample.trueAcceleration, vertical);
        this.accumulatedForward = v3add(
          this.accumulatedForward,
          v3scaled(horizontal, sign * sample.dt),
        );
        this.totalEvidenceGSeconds += v3norm(horizontal) * sample.dt;
      }
    } finally {
      this.anchorFix = { timestamp: gps.timestamp, speedMps: speed };
      this.discardPending(gps.timestamp);
    }
  }

  /**
   * The converged orientation, or null until gravity has settled and the
   * forward evidence has reached both magnitude and consistency thresholds.
   */
  estimate(): VehicleOrientationEstimate | null {
    if (!this.isGravitySettled()) return null;
    const up = this.upFromGravity();
    if (up === null) return null;

    const evidence = v3norm(this.accumulatedForward);
    if (
      !(evidence >= this.config.minForwardEvidenceGSeconds) ||
      !(this.totalEvidenceGSeconds > 0)
    ) {
      return null;
    }

    const consistency = evidence / this.totalEvidenceGSeconds;
    if (!(consistency >= this.config.minConsistencyRatio)) return null;

    // Gram–Schmidt: orthogonalize forward against up, then complete the
    // right-handed frame.
    const rawForward = v3normalized(this.accumulatedForward);
    if (rawForward === null) return null;
    const projected = v3sub(rawForward, v3scaled(up, v3dot(rawForward, up)));
    const forward = v3normalized(projected);
    if (forward === null) return null;
    const right = v3cross(forward, up);

    const evidenceTerm = this.config.evidenceSaturationGSeconds > 0
      ? Math.min(1, evidence / this.config.evidenceSaturationGSeconds)
      : 1;
    const confidence = Math.min(1, Math.max(0, evidenceTerm * consistency));

    return new VehicleOrientationEstimate(forward, right, up, confidence);
  }

  // MARK: - Private

  private isGravitySettled(): boolean {
    return this.gravityEMA !== null &&
      this.quasiStaticSeconds >= this.config.minStationaryDurationSeconds;
  }

  /** Up axis in device coordinates: opposite the gravity reading. */
  private upFromGravity(): Vector3 | null {
    if (this.gravityEMA === null) return null;
    return v3normalized(v3neg(this.gravityEMA));
  }

  private smoothingFactor(dt: number): number {
    if (!(dt > 0)) return 0;
    if (!(this.config.gravityTimeConstantSeconds > 0)) return 1;
    return 1 - Math.exp(-dt / this.config.gravityTimeConstantSeconds);
  }

  private discardPending(upTo: number): void {
    this.pending = this.pending.filter((p) => !(p.timestamp <= upTo));
  }
}
