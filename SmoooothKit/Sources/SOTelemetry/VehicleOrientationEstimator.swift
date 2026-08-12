import Foundation
import SOCore

/// Tunable thresholds for `VehicleOrientationEstimator` (spec §19).
///
/// The estimator recovers the vehicle's axes from a phone mounted at an
/// arbitrary orientation, using a short stationary window (gravity) followed
/// by a few seconds of straight-line acceleration cross-checked against GPS
/// speed (calibration flow, spec §16). Every threshold lives here — nothing
/// is hard-coded in the estimation logic.
public struct OrientationConfig: Codable, Sendable, Equatable {
    /// Time constant of the gravity low-pass EMA, in seconds. Smaller tracks
    /// mount shifts faster; larger rejects more vibration.
    public var gravityTimeConstantSeconds: Double

    /// Quasi-static gate half-width, in g: a sample may update the gravity
    /// estimate only when its acceleration norm is within this distance of 1 g.
    public var maxGravityDeviationG: Double

    /// Consecutive quasi-static time, in seconds, required before a sample
    /// updates the gravity estimate. Debounces isolated samples whose noise
    /// happens to cancel real dynamics back to ~1 g.
    public var quasiStaticDebounceSeconds: Double

    /// Accumulated quasi-static observation time, in seconds, before the
    /// gravity direction (and thus the up axis) is trusted.
    public var minStationaryDurationSeconds: Double

    /// Minimum |dv/dt| between consecutive GPS speeds, in m/s², for the
    /// window between those fixes to count as straight-line acceleration.
    public var minAccelerationMps2: Double

    /// Maximum |yaw rate| about the estimated up axis, in rad/s, anywhere
    /// inside an acceleration window; above this the whole window is
    /// rejected as turning.
    public var maxYawRateRadPerSec: Double

    /// Maximum spacing between consecutive GPS fixes, in seconds, for their
    /// dv/dt to be trusted (also bounds the inertial buffer).
    public var maxGPSGapSeconds: Double

    /// Minimum accumulated forward evidence, in g·seconds, before an
    /// estimate is produced.
    public var minForwardEvidenceGSeconds: Double

    /// Evidence level, in g·seconds, at which the evidence term of
    /// `confidence` saturates at 1.
    public var evidenceSaturationGSeconds: Double

    /// Minimum consistency — norm of the vector-summed horizontal evidence
    /// divided by the summed norms, 0...1 — before an estimate is produced.
    public var minConsistencyRatio: Double

    public init(
        gravityTimeConstantSeconds: Double,
        maxGravityDeviationG: Double,
        quasiStaticDebounceSeconds: Double,
        minStationaryDurationSeconds: Double,
        minAccelerationMps2: Double,
        maxYawRateRadPerSec: Double,
        maxGPSGapSeconds: Double,
        minForwardEvidenceGSeconds: Double,
        evidenceSaturationGSeconds: Double,
        minConsistencyRatio: Double
    ) {
        self.gravityTimeConstantSeconds = gravityTimeConstantSeconds
        self.maxGravityDeviationG = maxGravityDeviationG
        self.quasiStaticDebounceSeconds = quasiStaticDebounceSeconds
        self.minStationaryDurationSeconds = minStationaryDurationSeconds
        self.minAccelerationMps2 = minAccelerationMps2
        self.maxYawRateRadPerSec = maxYawRateRadPerSec
        self.maxGPSGapSeconds = maxGPSGapSeconds
        self.minForwardEvidenceGSeconds = minForwardEvidenceGSeconds
        self.evidenceSaturationGSeconds = evidenceSaturationGSeconds
        self.minConsistencyRatio = minConsistencyRatio
    }

    /// Defaults tuned for the spec §16 calibration flow (~2 s stationary,
    /// then several seconds of straight-line acceleration, GPS at ≥1 Hz).
    public static let `default` = OrientationConfig(
        gravityTimeConstantSeconds: 0.5,
        maxGravityDeviationG: 0.02,
        quasiStaticDebounceSeconds: 0.05,
        minStationaryDurationSeconds: 1.0,
        minAccelerationMps2: 0.8,
        maxYawRateRadPerSec: 0.15,
        maxGPSGapSeconds: 3.0,
        minForwardEvidenceGSeconds: 0.5,
        evidenceSaturationGSeconds: 1.5,
        minConsistencyRatio: 0.8
    )
}

/// A converged device→vehicle orientation: the vehicle's forward/right/up
/// axes expressed as orthonormal unit vectors in the *device* frame.
public struct VehicleOrientationEstimate: Sendable, Equatable {
    /// Vehicle forward (+longitudinal) axis in device coordinates; unit length.
    public var forwardDevice: Vector3
    /// Vehicle right (+lateral) axis in device coordinates; unit length,
    /// equals `forwardDevice × upDevice` (right-handed frame).
    public var rightDevice: Vector3
    /// Vehicle up (+vertical) axis in device coordinates; unit length.
    public var upDevice: Vector3
    /// Calibration quality in 0...1 — grows with accumulated forward
    /// evidence and the directional consistency of that evidence.
    public var confidence: Double

    public init(forwardDevice: Vector3, rightDevice: Vector3, upDevice: Vector3, confidence: Double) {
        self.forwardDevice = forwardDevice
        self.rightDevice = rightDevice
        self.upDevice = upDevice
        self.confidence = confidence
    }

    /// Transforms one device-frame inertial sample into the vehicle frame.
    ///
    /// Gravity is removed assuming exactly 1 g along `-upDevice` (the raw
    /// accelerometer reads the unit down vector at rest — see the shared
    /// sign convention); yaw rate is the gyro component about `upDevice`
    /// (+ = turning left, right-hand rule).
    public func transform(_ imu: IMUSample) -> VehicleFrameSample {
        let reading = Vector3(x: imu.accelX, y: imu.accelY, z: imu.accelZ)
        let gyro = Vector3(x: imu.gyroX, y: imu.gyroY, z: imu.gyroZ)
        let trueAcceleration = reading + upDevice
        return VehicleFrameSample(
            timestamp: imu.timestamp,
            longitudinal: trueAcceleration.dot(forwardDevice),
            lateral: trueAcceleration.dot(rightDevice),
            vertical: trueAcceleration.dot(upDevice),
            yawRate: gyro.dot(upDevice)
        )
    }
}

/// Recovers the vehicle's axes from a phone mounted at an arbitrary,
/// unknown orientation (spec §19).
///
/// Feed interleaved IMU and GPS samples in timestamp order:
/// - **Up** comes from an EMA of the raw accelerometer, updated only during
///   quasi-static moments (norm ≈ 1 g); `upDevice = -normalize(gravity)`.
/// - **Forward** comes from horizontal true acceleration accumulated during
///   windows where GPS-derived |dv/dt| is high and yaw rate is low —
///   braking windows count too (their sign is flipped by sign(dv/dt)).
/// - **Right** completes the right-handed frame (`forward × up`).
///
/// `estimate` stays `nil` until gravity has settled and enough consistent
/// forward evidence has accumulated (thresholds in `OrientationConfig`).
public struct VehicleOrientationEstimator: Sendable {
    private let config: OrientationConfig

    /// EMA of the raw accelerometer reading; points toward the earth.
    private var gravityEMA: Vector3?
    private var lastIMUTimestamp: Double?
    /// Consecutive quasi-static time ending at the latest IMU sample.
    private var staticStreakSeconds = 0.0
    /// Total quasi-static time that actually updated the gravity EMA.
    private var quasiStaticSeconds = 0.0

    /// IMU-derived quantities buffered since the last GPS fix, so a window
    /// can be scored retroactively once the fix that closes it arrives.
    private struct PendingSample: Sendable {
        var timestamp: Double
        var dt: Double
        var trueAcceleration: Vector3
        var gyro: Vector3
    }

    private var pending: [PendingSample] = []
    private var lastGPSFix: (timestamp: Double, speedMps: Double)?
    /// Vector sum of sign(dv/dt)-corrected horizontal acceleration, g·s.
    private var accumulatedForward: Vector3 = .zero
    /// Scalar sum of horizontal acceleration norms, g·s (consistency denominator).
    private var totalEvidenceGSeconds = 0.0

    public init(config: OrientationConfig = .default) {
        self.config = config
    }

    /// Ingests one device-frame inertial sample. Samples must arrive in
    /// timestamp order; out-of-order samples are tolerated but contribute no
    /// elapsed time.
    public mutating func ingest(imu: IMUSample) {
        let reading = Vector3(x: imu.accelX, y: imu.accelY, z: imu.accelZ)
        let dt: Double
        if let last = lastIMUTimestamp {
            dt = max(0, imu.timestamp - last)
            lastIMUTimestamp = max(last, imu.timestamp)
        } else {
            dt = 0
            lastIMUTimestamp = imu.timestamp
        }

        if abs(reading.norm - 1) <= config.maxGravityDeviationG {
            staticStreakSeconds += dt
            if var gravity = gravityEMA {
                if staticStreakSeconds >= config.quasiStaticDebounceSeconds {
                    let alpha = smoothingFactor(dt: dt)
                    gravity = gravity + (reading - gravity).scaled(by: alpha)
                    gravityEMA = gravity
                    quasiStaticSeconds += dt
                }
            } else {
                gravityEMA = reading
            }
        } else {
            staticStreakSeconds = 0
        }

        guard isGravitySettled, let gravity = gravityEMA else { return }
        pending.append(PendingSample(
            timestamp: imu.timestamp,
            dt: dt,
            trueAcceleration: reading - gravity,
            gyro: Vector3(x: imu.gyroX, y: imu.gyroY, z: imu.gyroZ)
        ))
        // Samples older than any trustable GPS window can never be scored.
        let horizon = imu.timestamp - config.maxGPSGapSeconds
        pending.removeAll { $0.timestamp < horizon }
    }

    /// Ingests one GPS fix. Fixes with a negative `horizontalAccuracy` or a
    /// missing/negative speed are ignored (invalid per platform convention).
    public mutating func ingest(gps: GPSSample) {
        guard gps.horizontalAccuracy >= 0, let speed = gps.speed, speed >= 0 else { return }
        guard let last = lastGPSFix else {
            lastGPSFix = (gps.timestamp, speed)
            discardPending(upTo: gps.timestamp)
            return
        }
        let dtGPS = gps.timestamp - last.timestamp
        guard dtGPS > 0 else { return }   // out-of-order or duplicate fix
        defer {
            lastGPSFix = (gps.timestamp, speed)
            discardPending(upTo: gps.timestamp)
        }
        guard dtGPS <= config.maxGPSGapSeconds else { return }

        let dvdt = (speed - last.speedMps) / dtGPS
        guard abs(dvdt) >= config.minAccelerationMps2, let up = upFromGravity else { return }

        let window = pending.filter { $0.timestamp > last.timestamp && $0.timestamp <= gps.timestamp }
        guard !window.isEmpty,
              window.allSatisfy({ abs($0.gyro.dot(up)) <= config.maxYawRateRadPerSec })
        else { return }

        let sign: Double = dvdt >= 0 ? 1 : -1
        for sample in window where sample.dt > 0 {
            let vertical = up.scaled(by: sample.trueAcceleration.dot(up))
            let horizontal = sample.trueAcceleration - vertical
            accumulatedForward = accumulatedForward + horizontal.scaled(by: sign * sample.dt)
            totalEvidenceGSeconds += horizontal.norm * sample.dt
        }
    }

    /// The converged orientation, or `nil` until gravity has settled for
    /// `minStationaryDurationSeconds` and the forward evidence has reached
    /// both the magnitude and consistency thresholds.
    public var estimate: VehicleOrientationEstimate? {
        guard isGravitySettled, let up = upFromGravity else { return nil }

        let evidence = accumulatedForward.norm
        guard evidence >= config.minForwardEvidenceGSeconds,
              totalEvidenceGSeconds > 0
        else { return nil }

        let consistency = evidence / totalEvidenceGSeconds
        guard consistency >= config.minConsistencyRatio else { return nil }

        // Gram–Schmidt: orthogonalize forward against up, then complete the
        // right-handed frame (device aligned with vehicle: fwd=+Y, up=+Z → right=+X).
        guard let rawForward = accumulatedForward.normalized() else { return nil }
        let projected = rawForward - up.scaled(by: rawForward.dot(up))
        guard let forward = projected.normalized() else { return nil }
        let right = forward.cross(up)

        let evidenceTerm = config.evidenceSaturationGSeconds > 0
            ? min(1, evidence / config.evidenceSaturationGSeconds)
            : 1
        let confidence = min(1, max(0, evidenceTerm * consistency))

        return VehicleOrientationEstimate(
            forwardDevice: forward,
            rightDevice: right,
            upDevice: up,
            confidence: confidence
        )
    }

    // MARK: - Private

    private var isGravitySettled: Bool {
        gravityEMA != nil && quasiStaticSeconds >= config.minStationaryDurationSeconds
    }

    /// Up axis in device coordinates: opposite the gravity reading, which
    /// points toward the earth (rest reading = unit down vector).
    private var upFromGravity: Vector3? {
        gravityEMA.flatMap { (-$0).normalized() }
    }

    private func smoothingFactor(dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        guard config.gravityTimeConstantSeconds > 0 else { return 1 }
        return 1 - exp(-dt / config.gravityTimeConstantSeconds)
    }

    private mutating func discardPending(upTo timestamp: Double) {
        pending.removeAll { $0.timestamp <= timestamp }
    }
}
