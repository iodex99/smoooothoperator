// Port of SmoooothKit SOIntegrity/RunIntegrityEngine.swift.
// Check order, streak/reset semantics, two-pointer scans, median and
// percentile95 index arithmetic all mirror the Swift reference exactly.
// Swift ClosedRange bands are represented as inclusive {min, max}.

import { distanceMeters } from "./geo.ts";
import {
  gapDuration,
  type GPSSample,
  type IMUSample,
  type IntegrityFlag,
  type ProcessedTrajectory,
  type RunVerificationStatus,
} from "./types.ts";

/** Inclusive band, mirroring Swift `ClosedRange<Double>`. */
export interface ClosedBand {
  min: number;
  max: number;
}

function bandContains(band: ClosedBand, value: number): boolean {
  return value >= band.min && value <= band.max;
}

/** Thresholds for run integrity evaluation (spec §45). */
export interface IntegrityConfig {
  maxPlausibleSpeedMps: number;
  minImpossibleSpeedPairs: number;
  maxPlausibleAccelMps2: number;
  minImpossibleAccelPairs: number;
  speedRatioBand: ClosedBand;
  minRatioSamples: number;
  minAccuracyVariance: number;
  minClockJitterSeconds: number;
  deadIMUDynamicsG: number;
  gyroHeadingRatioBand: ClosedBand;
  minHeadingRateRadPerSec: number;
  imuCheckSpeedMps: number;
  suspiciousGapSeconds: number;
  maxRejectedFraction: number;
  minLocationConfidence: number;
}

/** Mirrors Swift `IntegrityConfig.default`. */
export const DEFAULT_INTEGRITY_CONFIG: IntegrityConfig = {
  maxPlausibleSpeedMps: 90,
  minImpossibleSpeedPairs: 3,
  maxPlausibleAccelMps2: 12,
  minImpossibleAccelPairs: 2,
  speedRatioBand: { min: 0.7, max: 1.3 },
  minRatioSamples: 50,
  minAccuracyVariance: 1e-6,
  minClockJitterSeconds: 1e-4,
  deadIMUDynamicsG: 0.01,
  gyroHeadingRatioBand: { min: 0.4, max: 1.8 },
  minHeadingRateRadPerSec: 0.05,
  imuCheckSpeedMps: 5,
  suspiciousGapSeconds: 4,
  maxRejectedFraction: 0.01,
  minLocationConfidence: 50,
};

export type IntegritySeverity = "warning" | "critical";

/** One integrity signal with its evidence. */
export interface IntegrityFinding {
  flag: IntegrityFlag;
  severity: IntegritySeverity;
  /** Human-readable evidence — shown to ops, never used in logic. */
  detail: string;
}

/** Course-adherence summary handed in by the caller. */
export interface RouteAdherence {
  expectedGates: number;
  gatesHit: number;
  deviationDetected: boolean;
}

/** The engine's output: findings + the verdict they imply. */
export interface IntegrityReport {
  findings: IntegrityFinding[];
  verdict: RunVerificationStatus;
}

/** Evaluates a completed run for cheating and data-quality problems. */
export function evaluateRunIntegrity(
  rawGPS: readonly GPSSample[],
  rawIMU: readonly IMUSample[],
  trajectory: ProcessedTrajectory,
  locationConfidence: number | null,
  routeAdherence: RouteAdherence | null,
  config: IntegrityConfig = DEFAULT_INTEGRITY_CONFIG,
): IntegrityReport {
  let findings: IntegrityFinding[] = [];

  findings = findings.concat(timestampFindings(rawGPS));
  findings = findings.concat(impossiblePhysicsFindings(rawGPS, config));
  findings = findings.concat(speedRatioFindings(rawGPS, config));
  findings = findings.concat(mockSignatureFindings(rawGPS, rawIMU, config));
  findings = findings.concat(gapAndJumpFindings(trajectory, config));
  findings = findings.concat(routeFindings(routeAdherence));

  if (
    locationConfidence !== null &&
    locationConfidence < config.minLocationConfidence
  ) {
    findings.push({
      flag: "gpsJump",
      severity: "warning",
      detail:
        `location confidence ${locationConfidence} below ${config.minLocationConfidence}`,
    });
  }

  const verdict: RunVerificationStatus =
    findings.some((f) => f.severity === "critical")
      ? "invalid"
      : findings.length > 0
      ? "questionable"
      : "verified";

  return { findings, verdict };
}

// MARK: - Checks

function timestampFindings(rawGPS: readonly GPSSample[]): IntegrityFinding[] {
  let regressions = 0;
  for (let i = 1; i < rawGPS.length; i++) {
    if (rawGPS[i].timestamp <= rawGPS[i - 1].timestamp) regressions += 1;
  }
  if (regressions === 0) return [];
  return [{
    flag: "timestampAnomaly",
    severity: "critical",
    detail: `${regressions} timestamp regression(s) in raw GPS`,
  }];
}

function impossiblePhysicsFindings(
  rawGPS: readonly GPSSample[],
  config: IntegrityConfig,
): IntegrityFinding[] {
  const findings: IntegrityFinding[] = [];

  const impossibleReported = rawGPS
    .map((s) => s.speed)
    .filter((s): s is number => s !== null)
    .filter((s) => s > config.maxPlausibleSpeedMps);

  // Implied speed must stay impossible across consecutive pairs.
  let impliedStreak = 0;
  let sustainedImpliedRuns = 0;
  for (let i = 1; i < rawGPS.length; i++) {
    const a = rawGPS[i - 1];
    const b = rawGPS[i];
    const dt = b.timestamp - a.timestamp;
    if (!(dt > 0)) continue;
    if (
      distanceMeters(a.coordinate, b.coordinate) / dt >
        config.maxPlausibleSpeedMps
    ) {
      impliedStreak += 1;
      if (impliedStreak === config.minImpossibleSpeedPairs) {
        sustainedImpliedRuns += 1;
      }
    } else {
      impliedStreak = 0;
    }
  }
  if (impossibleReported.length > 0 || sustainedImpliedRuns > 0) {
    findings.push({
      flag: "impossibleSpeed",
      severity: "critical",
      detail: `reported>${Math.trunc(config.maxPlausibleSpeedMps)}: ` +
        `${impossibleReported.length}, sustained implied runs: ${sustainedImpliedRuns}`,
    });
  }

  // Reported-speed acceleration, sustained across consecutive pairs.
  // Missing speeds reset the streak; non-positive dt preserves it (continue).
  let accelStreak = 0;
  let impossibleAccelRuns = 0;
  for (let index = 1; index < Math.max(rawGPS.length, 1); index++) {
    const v0 = rawGPS[index - 1].speed;
    const v1 = rawGPS[index].speed;
    if (v0 === null || v1 === null) {
      accelStreak = 0;
      continue;
    }
    const dt = rawGPS[index].timestamp - rawGPS[index - 1].timestamp;
    if (!(dt > 0)) continue;
    if (Math.abs(v1 - v0) / dt > config.maxPlausibleAccelMps2) {
      accelStreak += 1;
      if (accelStreak === config.minImpossibleAccelPairs) {
        impossibleAccelRuns += 1;
      }
    } else {
      accelStreak = 0;
    }
  }
  if (impossibleAccelRuns > 0) {
    findings.push({
      flag: "impossibleAcceleration",
      severity: "critical",
      detail: `${impossibleAccelRuns} sustained |dv/dt| run(s) above ` +
        `${config.maxPlausibleAccelMps2} m/s²`,
    });
  }
  return findings;
}

/** Implied-vs-reported speed: a manipulated clock shifts the distribution. */
function speedRatioFindings(
  rawGPS: readonly GPSSample[],
  config: IntegrityConfig,
): IntegrityFinding[] {
  const ratios: number[] = [];
  for (let i = 1; i < rawGPS.length; i++) {
    const a = rawGPS[i - 1];
    const b = rawGPS[i];
    const dt = b.timestamp - a.timestamp;
    if (!(dt > 0) || b.speed === null || !(b.speed > 3)) continue;
    const implied = distanceMeters(a.coordinate, b.coordinate) / dt;
    ratios.push(implied / b.speed);
  }
  if (ratios.length < config.minRatioSamples) return [];
  const sorted = ratios.slice().sort((a, b) => a - b);
  const median = sorted[Math.trunc(ratios.length / 2)];
  if (bandContains(config.speedRatioBand, median)) return [];
  return [{
    flag: "timestampAnomaly",
    severity: "critical",
    detail:
      `median implied/reported speed ratio ${median.toFixed(2)} outside ` +
      `${config.speedRatioBand.min}...${config.speedRatioBand.max}`,
  }];
}

/**
 * Mock-location signatures. Each alone is circumstantial (warning); two or
 * more together are a scripted feed (critical). The gyro/heading consistency
 * finding is appended BEFORE the mockLocation finding, as in Swift.
 */
function mockSignatureFindings(
  rawGPS: readonly GPSSample[],
  rawIMU: readonly IMUSample[],
  config: IntegrityConfig,
): IntegrityFinding[] {
  if (rawGPS.length < 50) return [];
  const signatures: string[] = [];

  const accuracies = rawGPS.map((s) => s.horizontalAccuracy);
  const meanAccuracy = accuracies.reduce((a, b) => a + b, 0) /
    accuracies.length;
  const accuracyVariance = accuracies.reduce(
    (sum, a) => sum + (a - meanAccuracy) * (a - meanAccuracy),
    0,
  ) / accuracies.length;
  if (accuracyVariance < config.minAccuracyVariance) {
    signatures.push("zero accuracy variance");
  }

  const dts: number[] = [];
  for (let i = 1; i < rawGPS.length; i++) {
    const dt = rawGPS[i].timestamp - rawGPS[i - 1].timestamp;
    if (dt > 0) dts.push(dt);
  }
  if (dts.length > 10) {
    const meanDt = dts.reduce((a, b) => a + b, 0) / dts.length;
    let maxJitter = 0;
    for (const dt of dts) {
      maxJitter = Math.max(maxJitter, Math.abs(dt - meanDt));
    }
    if (maxJitter < config.minClockJitterSeconds) {
      signatures.push("metronome fix clock");
    }
  }

  // Dead IMU while GPS claims motion: the phone never felt the drive.
  const imuFindings: IntegrityFinding[] = [];
  const maxDeviation = movingIMUMaxDeviation(rawGPS, rawIMU, config);
  if (maxDeviation !== null && maxDeviation < config.deadIMUDynamicsG) {
    signatures.push("dead IMU while moving");
  }

  // Gyro must agree with the turn rate GPS course shows.
  const ratio = gyroHeadingRatio(rawGPS, rawIMU, config);
  if (ratio !== null && !bandContains(config.gyroHeadingRatioBand, ratio)) {
    imuFindings.push({
      flag: "sensorMismatch",
      severity: "warning",
      detail: `p95 gyro / p95 GPS heading rate = ${ratio.toFixed(2)} outside ` +
        `${config.gyroHeadingRatioBand.min}...${config.gyroHeadingRatioBand.max}`,
    });
  }

  const findings = imuFindings;
  if (signatures.length >= 2) {
    findings.push({
      flag: "mockLocation",
      severity: "critical",
      detail: signatures.join(" + "),
    });
  } else if (signatures.length === 1) {
    findings.push({
      flag: "mockLocation",
      severity: "warning",
      detail: signatures[0],
    });
  }
  return findings;
}

/**
 * Max |accel norm − 1 g| over IMU samples taken while GPS speed exceeds the
 * check threshold. Null when there's no moving overlap (needs >100 samples).
 */
function movingIMUMaxDeviation(
  rawGPS: readonly GPSSample[],
  rawIMU: readonly IMUSample[],
  config: IntegrityConfig,
): number | null {
  if (rawIMU.length === 0 || rawGPS.length === 0) return null;
  const deviations: number[] = [];
  let gpsIndex = 0;
  for (const sample of rawIMU) {
    while (
      gpsIndex + 1 < rawGPS.length &&
      rawGPS[gpsIndex + 1].timestamp <= sample.timestamp
    ) {
      gpsIndex += 1;
    }
    const speed = rawGPS[gpsIndex].speed;
    if (speed === null || !(speed > config.imuCheckSpeedMps)) continue;
    const norm = Math.sqrt(
      sample.accelX * sample.accelX +
        sample.accelY * sample.accelY +
        sample.accelZ * sample.accelZ,
    );
    deviations.push(Math.abs(norm - 1));
  }
  if (!(deviations.length > 100)) return null;
  let max = -Infinity;
  for (const d of deviations) max = Math.max(max, d);
  return max;
}

/**
 * p95(|gyro|) over moving IMU samples divided by p95(|GPS heading rate|).
 * Null when the run has too little turning to assess.
 */
function gyroHeadingRatio(
  rawGPS: readonly GPSSample[],
  rawIMU: readonly IMUSample[],
  config: IntegrityConfig,
): number | null {
  if (rawIMU.length === 0) return null;

  // Heading rate over ~1 s spans (`later` persists across iterations).
  const headingRates: number[] = [];
  let later = 0;
  for (let index = 0; index < rawGPS.length; index++) {
    while (
      later < rawGPS.length &&
      rawGPS[later].timestamp - rawGPS[index].timestamp < 1.0
    ) {
      later += 1;
    }
    if (later >= rawGPS.length) break;
    const a = rawGPS[index];
    const b = rawGPS[later];
    const dt = b.timestamp - a.timestamp;
    if (
      !(dt > 0) || a.course === null || b.course === null ||
      b.speed === null || !(b.speed > config.imuCheckSpeedMps)
    ) {
      continue;
    }
    let delta = (b.course - a.course) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    headingRates.push(Math.abs(delta * Math.PI / 180 / dt));
  }
  if (headingRates.length < 20) return null;
  const headingP95 = percentile95(headingRates);
  if (!(headingP95 > config.minHeadingRateRadPerSec)) return null;

  const gyroNorms: number[] = [];
  let gpsIndex = 0;
  for (const sample of rawIMU) {
    while (
      gpsIndex + 1 < rawGPS.length &&
      rawGPS[gpsIndex + 1].timestamp <= sample.timestamp
    ) {
      gpsIndex += 1;
    }
    const speed = rawGPS[gpsIndex].speed;
    if (speed === null || !(speed > config.imuCheckSpeedMps)) continue;
    gyroNorms.push(Math.sqrt(
      sample.gyroX * sample.gyroX +
        sample.gyroY * sample.gyroY +
        sample.gyroZ * sample.gyroZ,
    ));
  }
  if (!(gyroNorms.length > 100)) return null;
  return percentile95(gyroNorms) / headingP95;
}

function percentile95(values: readonly number[]): number {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.trunc(sorted.length * 0.95))];
}

function gapAndJumpFindings(
  trajectory: ProcessedTrajectory,
  config: IntegrityConfig,
): IntegrityFinding[] {
  const findings: IntegrityFinding[] = [];

  const longGaps = trajectory.gaps.filter(
    (g) => gapDuration(g) > config.suspiciousGapSeconds,
  );
  if (longGaps.length > 0) {
    findings.push({
      flag: "suspiciousGap",
      severity: "warning",
      detail: `${longGaps.length} gap(s) longer than ` +
        `${Math.trunc(config.suspiciousGapSeconds)}s`,
    });
  }

  const total = trajectory.points.length + trajectory.rejectedSampleCount;
  if (total > 0) {
    const rejectedFraction = trajectory.rejectedSampleCount / total;
    if (rejectedFraction > config.maxRejectedFraction) {
      findings.push({
        flag: "gpsJump",
        severity: "warning",
        detail: `${
          (rejectedFraction * 100).toFixed(1)
        }% of raw fixes rejected by filtering`,
      });
    }
  }
  return findings;
}

function routeFindings(
  routeAdherence: RouteAdherence | null,
): IntegrityFinding[] {
  if (routeAdherence === null) return [];
  const findings: IntegrityFinding[] = [];
  if (routeAdherence.gatesHit < routeAdherence.expectedGates) {
    findings.push({
      flag: "routeSkip",
      severity: "critical",
      detail:
        `${routeAdherence.gatesHit}/${routeAdherence.expectedGates} checkpoints hit in order`,
    });
  }
  if (routeAdherence.deviationDetected) {
    findings.push({
      flag: "routeSkip",
      severity: "critical",
      detail: "run left the course corridor beyond the grace period",
    });
  }
  return findings;
}
