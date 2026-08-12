// Port of SmoooothKit SOModels/ScoringWeights.swift, SOScoring/ScoreBreakdown.swift,
// ScoringConfig.swift, ScoringEngine.swift.
//
// Determinism contract (ADR-0002): curve lookups and + − × ÷ √ only;
// quantization to integer bps via half-up rounding BEFORE integer-weighted
// combination with truncating division.

import { type Breakpoint, PiecewiseLinearCurve } from "./curve.ts";
import {
  type DrivingEvent,
  type ProcessedTrajectory,
  type SpeedLimitSegment,
  trajectoryDuration,
  trajectoryTotalDistanceMeters,
  type VehicleFrameSample,
} from "./types.ts";

/** Weighting of the four sub-scores, in integer basis points (sum 10_000). */
export interface ScoringWeights {
  paceBps: number;
  smoothnessBps: number;
  controlBps: number;
  complianceBps: number;
}

export function weightsAreValid(weights: ScoringWeights): boolean {
  const parts = [
    weights.paceBps,
    weights.smoothnessBps,
    weights.controlBps,
    weights.complianceBps,
  ];
  return parts.every((p) => Number.isInteger(p) && p >= 0) &&
    parts.reduce((a, b) => a + b, 0) === 10_000;
}

/** The four sub-scores of a run, each in integer basis points (0...10_000). */
export interface ScoreBreakdown {
  paceBps: number;
  smoothnessBps: number;
  controlBps: number;
  complianceBps: number;
}

/**
 * Final score in 0...10_000. Exact integer arithmetic, truncating division —
 * mirrors Swift `ScoreBreakdown.finalScore(weights:)` operation order.
 */
export function finalScore(
  breakdown: ScoreBreakdown,
  weights: ScoringWeights,
): number {
  if (!weightsAreValid(weights)) {
    throw new Error("scoring weights must sum to 10_000");
  }
  const weighted = breakdown.paceBps * weights.paceBps +
    breakdown.smoothnessBps * weights.smoothnessBps +
    breakdown.controlBps * weights.controlBps +
    breakdown.complianceBps * weights.complianceBps;
  return Math.trunc(weighted / 10_000);
}

/** The versioned scoring configuration (spec §42), curves materialized. */
export interface ScoringConfig {
  version: string;
  weights: ScoringWeights;
  pace: {
    benchmarkRatioCurve: PiecewiseLinearCurve;
  };
  smoothness: {
    eventWeights: Record<string, number>;
    weightedEventsPerKmCurve: PiecewiseLinearCurve;
    jerkRMSCurve: PiecewiseLinearCurve;
    eventComponentBps: number;
    jerkComponentBps: number;
  };
  control: {
    brakingConsistencyCurve: PiecewiseLinearCurve;
    corneringConsistencyCurve: PiecewiseLinearCurve;
    oscillationRateCurve: PiecewiseLinearCurve;
    oscillationDeadbandG: number;
    brakingComponentBps: number;
    corneringComponentBps: number;
    oscillationComponentBps: number;
  };
  compliance: {
    graceMps: number;
    exceedanceCurve: PiecewiseLinearCurve;
    noDataBps: number;
  };
}

/** Structural validity — mirrors Swift `ScoringConfig.isValid`. */
export function scoringConfigIsValid(config: ScoringConfig): boolean {
  return weightsAreValid(config.weights) &&
    config.smoothness.eventComponentBps >= 0 &&
    config.smoothness.jerkComponentBps >= 0 &&
    config.smoothness.eventComponentBps + config.smoothness.jerkComponentBps ===
      10_000 &&
    config.control.brakingComponentBps >= 0 &&
    config.control.corneringComponentBps >= 0 &&
    config.control.oscillationComponentBps >= 0 &&
    config.control.brakingComponentBps + config.control.corneringComponentBps +
          config.control.oscillationComponentBps === 10_000 &&
    config.compliance.noDataBps >= 0 && config.compliance.noDataBps <= 10_000;
}

// MARK: - Config loading

function asObject(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`scoring config: ${path} must be an object`);
  }
  return value as Record<string, unknown>;
}

function asNumber(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`scoring config: ${path} must be a finite number`);
  }
  return value;
}

function asString(value: unknown, path: string): string {
  if (typeof value !== "string") {
    throw new Error(`scoring config: ${path} must be a string`);
  }
  return value;
}

function asCurve(value: unknown, path: string): PiecewiseLinearCurve {
  const obj = asObject(value, path);
  const raw = obj.breakpoints;
  if (!Array.isArray(raw)) {
    throw new Error(`scoring config: ${path}.breakpoints must be an array`);
  }
  const breakpoints: Breakpoint[] = raw.map((bp, i) => {
    const b = asObject(bp, `${path}.breakpoints[${i}]`);
    return {
      x: asNumber(b.x, `${path}.breakpoints[${i}].x`),
      y: asNumber(b.y, `${path}.breakpoints[${i}].y`),
    };
  });
  return new PiecewiseLinearCurve(breakpoints);
}

/**
 * Decodes and validates a parsed config JSON (canonical file:
 * `configs/scoring/v1.json`). Throws on structural invalidity — a bad config
 * must never score runs (mirrors Swift `ScoringConfig.load(from:)`).
 */
export function parseScoringConfig(json: unknown): ScoringConfig {
  const root = asObject(json, "root");
  const weightsObj = asObject(root.weights, "weights");
  const paceObj = asObject(root.pace, "pace");
  const smoothnessObj = asObject(root.smoothness, "smoothness");
  const controlObj = asObject(root.control, "control");
  const complianceObj = asObject(root.compliance, "compliance");

  const eventWeightsObj = asObject(
    smoothnessObj.eventWeights,
    "smoothness.eventWeights",
  );
  const eventWeights: Record<string, number> = {};
  for (const key of Object.keys(eventWeightsObj)) {
    eventWeights[key] = asNumber(
      eventWeightsObj[key],
      `smoothness.eventWeights.${key}`,
    );
  }

  const config: ScoringConfig = {
    version: asString(root.version, "version"),
    weights: {
      paceBps: asNumber(weightsObj.paceBps, "weights.paceBps"),
      smoothnessBps: asNumber(
        weightsObj.smoothnessBps,
        "weights.smoothnessBps",
      ),
      controlBps: asNumber(weightsObj.controlBps, "weights.controlBps"),
      complianceBps: asNumber(
        weightsObj.complianceBps,
        "weights.complianceBps",
      ),
    },
    pace: {
      benchmarkRatioCurve: asCurve(
        paceObj.benchmarkRatioCurve,
        "pace.benchmarkRatioCurve",
      ),
    },
    smoothness: {
      eventWeights,
      weightedEventsPerKmCurve: asCurve(
        smoothnessObj.weightedEventsPerKmCurve,
        "smoothness.weightedEventsPerKmCurve",
      ),
      jerkRMSCurve: asCurve(
        smoothnessObj.jerkRMSCurve,
        "smoothness.jerkRMSCurve",
      ),
      eventComponentBps: asNumber(
        smoothnessObj.eventComponentBps,
        "smoothness.eventComponentBps",
      ),
      jerkComponentBps: asNumber(
        smoothnessObj.jerkComponentBps,
        "smoothness.jerkComponentBps",
      ),
    },
    control: {
      brakingConsistencyCurve: asCurve(
        controlObj.brakingConsistencyCurve,
        "control.brakingConsistencyCurve",
      ),
      corneringConsistencyCurve: asCurve(
        controlObj.corneringConsistencyCurve,
        "control.corneringConsistencyCurve",
      ),
      oscillationRateCurve: asCurve(
        controlObj.oscillationRateCurve,
        "control.oscillationRateCurve",
      ),
      oscillationDeadbandG: asNumber(
        controlObj.oscillationDeadbandG,
        "control.oscillationDeadbandG",
      ),
      brakingComponentBps: asNumber(
        controlObj.brakingComponentBps,
        "control.brakingComponentBps",
      ),
      corneringComponentBps: asNumber(
        controlObj.corneringComponentBps,
        "control.corneringComponentBps",
      ),
      oscillationComponentBps: asNumber(
        controlObj.oscillationComponentBps,
        "control.oscillationComponentBps",
      ),
    },
    compliance: {
      graceMps: asNumber(complianceObj.graceMps, "compliance.graceMps"),
      exceedanceCurve: asCurve(
        complianceObj.exceedanceCurve,
        "compliance.exceedanceCurve",
      ),
      noDataBps: asNumber(complianceObj.noDataBps, "compliance.noDataBps"),
    },
  };

  if (!scoringConfigIsValid(config)) {
    throw new Error("scoring config: structurally invalid");
  }
  return config;
}

// MARK: - Engine

/** The scored result of a run. */
export interface ScoreResult {
  breakdown: ScoreBreakdown;
  finalScore: number;
  scoringVersion: string;
  hasComplianceData: boolean;
  /** Raw metric values behind each sub-score — never re-used in score math. */
  metrics: Record<string, number>;
}

/**
 * Curve output (Double bps) → integer bps, half-up rounding, clamped.
 * Swift mirror: `min(10_000, max(0, Int(bps.rounded())))`.
 */
function quantize(bps: number): number {
  return Math.min(10_000, Math.max(0, Math.round(bps)));
}

/** Integer-weighted combination with truncating division. */
function combine(
  parts: ReadonlyArray<[score: number, weightBps: number]>,
): number {
  let weighted = 0;
  for (const [score, weightBps] of parts) {
    weighted += score * weightBps;
  }
  return Math.trunc(weighted / 10_000);
}

/** Computes the four sub-scores and the final score (spec §§38–42). */
export function scoreRun(
  config: ScoringConfig,
  trajectory: ProcessedTrajectory,
  events: readonly DrivingEvent[],
  vehicleFrames: readonly VehicleFrameSample[],
  benchmarkSeconds: number,
  speedLimits: readonly SpeedLimitSegment[],
): ScoreResult {
  const metrics: Record<string, number> = {};

  const pace = paceScore(config, trajectory, benchmarkSeconds, metrics);
  const smoothness = smoothnessScore(
    config,
    trajectory,
    events,
    vehicleFrames,
    metrics,
  );
  const control = controlScore(config, events, vehicleFrames, metrics);
  const [compliance, hasData] = complianceScore(
    config,
    trajectory,
    speedLimits,
    metrics,
  );

  const breakdown: ScoreBreakdown = {
    paceBps: pace,
    smoothnessBps: smoothness,
    controlBps: control,
    complianceBps: compliance,
  };
  return {
    breakdown,
    finalScore: finalScore(breakdown, config.weights),
    scoringVersion: config.version,
    hasComplianceData: hasData,
    metrics,
  };
}

// MARK: - Pace (spec §39)

function paceScore(
  config: ScoringConfig,
  trajectory: ProcessedTrajectory,
  benchmarkSeconds: number,
  metrics: Record<string, number>,
): number {
  const duration = trajectoryDuration(trajectory);
  if (!(benchmarkSeconds > 0) || !(duration > 0)) return 0;
  const ratio = duration / benchmarkSeconds;
  metrics.paceBenchmarkRatio = ratio;
  return quantize(config.pace.benchmarkRatioCurve.valueAt(ratio));
}

// MARK: - Smoothness (spec §38)

function smoothnessScore(
  config: ScoringConfig,
  trajectory: ProcessedTrajectory,
  events: readonly DrivingEvent[],
  vehicleFrames: readonly VehicleFrameSample[],
  metrics: Record<string, number>,
): number {
  const kilometers = Math.max(
    trajectoryTotalDistanceMeters(trajectory) / 1000,
    0.001,
  );
  let weightedEvents = 0;
  for (const event of events) {
    weightedEvents += config.smoothness.eventWeights[event.kind] ?? 1.0;
  }
  const eventsPerKm = weightedEvents / kilometers;
  metrics.smoothnessWeightedEventsPerKm = eventsPerKm;
  const eventScore = config.smoothness.weightedEventsPerKmCurve.valueAt(
    eventsPerKm,
  );

  const jerkRMS = longitudinalJerkRMS(vehicleFrames);
  metrics.smoothnessJerkRMS = jerkRMS;
  const jerkScore = config.smoothness.jerkRMSCurve.valueAt(jerkRMS);

  return combine([
    [quantize(eventScore), config.smoothness.eventComponentBps],
    [quantize(jerkScore), config.smoothness.jerkComponentBps],
  ]);
}

/** RMS of d(longitudinal)/dt in g/s over the vehicle-frame stream. */
function longitudinalJerkRMS(frames: readonly VehicleFrameSample[]): number {
  let sumSquares = 0;
  let count = 0;
  for (let i = 1; i < frames.length; i++) {
    const a = frames[i - 1];
    const b = frames[i];
    const dt = b.timestamp - a.timestamp;
    if (!(dt > 0 && dt < 1)) continue;
    const jerk = (b.longitudinal - a.longitudinal) / dt;
    sumSquares += jerk * jerk;
    count += 1;
  }
  if (count === 0) return 0;
  return Math.sqrt(sumSquares / count);
}

// MARK: - Control (spec §40)

function controlScore(
  config: ScoringConfig,
  events: readonly DrivingEvent[],
  vehicleFrames: readonly VehicleFrameSample[],
  metrics: Record<string, number>,
): number {
  const brakingPeaks = events
    .filter((e) => e.kind === "braking" || e.kind === "hardBraking")
    .map((e) => e.peakMagnitudeG);
  const corneringPeaks = events
    .filter((e) => e.kind === "cornering" || e.kind === "hardCornering")
    .map((e) => e.peakMagnitudeG);

  const brakingStd = standardDeviation(brakingPeaks);
  const corneringStd = standardDeviation(corneringPeaks);
  metrics.controlBrakingPeakStd = brakingStd;
  metrics.controlCorneringPeakStd = corneringStd;

  const oscillation = oscillationRatePerMinute(config, vehicleFrames);
  metrics.controlOscillationPerMinute = oscillation;

  return combine([
    [
      quantize(config.control.brakingConsistencyCurve.valueAt(brakingStd)),
      config.control.brakingComponentBps,
    ],
    [
      quantize(config.control.corneringConsistencyCurve.valueAt(corneringStd)),
      config.control.corneringComponentBps,
    ],
    [
      quantize(config.control.oscillationRateCurve.valueAt(oscillation)),
      config.control.oscillationComponentBps,
    ],
  ]);
}

function standardDeviation(values: readonly number[]): number {
  if (!(values.length > 1)) return 0;
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  const variance = values.reduce(
    (sum, v) => sum + (v - mean) * (v - mean),
    0,
  ) / values.length;
  return Math.sqrt(variance);
}

/** Longitudinal sign flips per minute where |value| clears the deadband. */
function oscillationRatePerMinute(
  config: ScoringConfig,
  frames: readonly VehicleFrameSample[],
): number {
  if (frames.length === 0) return 0;
  const first = frames[0];
  const last = frames[frames.length - 1];
  if (!(last.timestamp > first.timestamp)) return 0;
  const deadband = config.control.oscillationDeadbandG;
  let flips = 0;
  let lastSign = 0;
  for (const frame of frames) {
    if (!(Math.abs(frame.longitudinal) > deadband)) continue;
    const sign = frame.longitudinal > 0 ? 1 : -1;
    if (lastSign !== 0 && sign !== lastSign) {
      flips += 1;
    }
    lastSign = sign;
  }
  const minutes = (last.timestamp - first.timestamp) / 60;
  return flips / minutes;
}

// MARK: - Compliance (spec §41)

function complianceScore(
  config: ScoringConfig,
  trajectory: ProcessedTrajectory,
  speedLimits: readonly SpeedLimitSegment[],
  metrics: Record<string, number>,
): [bps: number, hasData: boolean] {
  const limits = speedLimits.filter((s) => s.limitMps !== null);
  if (limits.length === 0 || !(trajectoryTotalDistanceMeters(trajectory) > 0)) {
    return [config.compliance.noDataBps, false];
  }

  // Distance-weighted relative overspeed beyond the grace margin.
  let exceedanceSum = 0;
  let coveredMeters = 0;
  for (let i = 1; i < trajectory.points.length; i++) {
    const a = trajectory.points[i - 1];
    const b = trajectory.points[i];
    const stepMeters = b.distanceAlongPathMeters - a.distanceAlongPathMeters;
    if (!(stepMeters > 0)) continue;
    const limit = limitAt(a.distanceAlongPathMeters, limits);
    if (limit === null) continue;
    coveredMeters += stepMeters;
    const over = a.speedMps - limit - config.compliance.graceMps;
    if (over > 0) {
      exceedanceSum += stepMeters * (over / limit);
    }
  }
  if (!(coveredMeters > 0)) {
    return [config.compliance.noDataBps, false];
  }
  const index = exceedanceSum / coveredMeters;
  metrics.complianceExceedanceIndex = index;
  return [quantize(config.compliance.exceedanceCurve.valueAt(index)), true];
}

function limitAt(
  meters: number,
  segments: readonly SpeedLimitSegment[],
): number | null {
  for (const segment of segments) {
    if (
      meters >= segment.startDistanceMeters &&
      meters < segment.endDistanceMeters
    ) {
      return segment.limitMps;
    }
  }
  return null;
}
