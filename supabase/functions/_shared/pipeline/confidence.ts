// Port of SmoooothKit SOTelemetry/LocationConfidence.swift.
// Sub-scores are curve outputs clamped to 0...100 and rounded to integers
// BEFORE weighting; the final score is sum(subScore × weight) / 100 in exact
// integer arithmetic (truncating division).

import { curve, PiecewiseLinearCurve } from "./curve.ts";
import {
  gapDuration,
  type GPSSample,
  type ProcessedTrajectory,
  trajectoryDuration,
} from "./types.ts";

/** How trustworthy a run's location data is, on a 0...100 scale (spec §22). */
export interface LocationConfidence {
  score: number;
  accuracyScore: number;
  continuityScore: number;
  plausibilityScore: number;
}

/** Response curves and weights for the confidence scorer. */
export interface LocationConfidenceConfig {
  /** Mean horizontal accuracy of valid raw fixes (meters, x) → 0...100 (y). */
  meanAccuracyCurve: PiecewiseLinearCurve;
  /** Fraction of the trajectory duration covered by gaps (0...1, x) → 0...100 (y). */
  gapFractionCurve: PiecewiseLinearCurve;
  /** Fraction of raw samples rejected by filtering (0...1, x) → 0...100 (y). */
  rejectionRateCurve: PiecewiseLinearCurve;
  accuracyWeight: number;
  continuityWeight: number;
  plausibilityWeight: number;
}

/** Spec §22 initial configuration — mirrors Swift `LocationConfidenceConfig.default`. */
export const DEFAULT_LOCATION_CONFIDENCE_CONFIG: LocationConfidenceConfig = {
  meanAccuracyCurve: curve([[5, 100], [10, 85], [20, 55], [30, 25], [50, 0]]),
  gapFractionCurve: curve([[0, 100], [0.05, 85], [0.15, 55], [0.3, 25], [
    0.6,
    0,
  ]]),
  rejectionRateCurve: curve([[0, 100], [0.02, 85], [0.1, 50], [0.3, 20], [
    0.6,
    0,
  ]]),
  accuracyWeight: 40,
  continuityWeight: 30,
  plausibilityWeight: 30,
};

/** Weights must be non-negative and sum to exactly 100. */
export function confidenceWeightsAreValid(
  config: LocationConfidenceConfig,
): boolean {
  const parts = [
    config.accuracyWeight,
    config.continuityWeight,
    config.plausibilityWeight,
  ];
  return parts.every((w) => w >= 0) && parts.reduce((a, b) => a + b, 0) === 100;
}

/**
 * Quantizes a curve output to an integer sub-score, clamped to 0...100.
 * Swift `Int(min(100, max(0, v)).rounded())` — non-negative, so Math.round
 * (half-up for positives) matches Swift's half-away-from-zero rounding.
 */
function subScore(curveValue: number): number {
  return Math.round(Math.min(100, Math.max(0, curveValue)));
}

/**
 * Scores how much the location data of a run can be trusted. `raw` must be
 * the same samples `trajectory` was processed from. Empty raw input or an
 * empty trajectory yields all-zero confidence.
 */
export function assessLocationConfidence(
  raw: readonly GPSSample[],
  trajectory: ProcessedTrajectory,
  config: LocationConfidenceConfig = DEFAULT_LOCATION_CONFIDENCE_CONFIG,
): LocationConfidence {
  if (!confidenceWeightsAreValid(config)) {
    throw new Error("confidence weights must sum to 100");
  }
  if (raw.length === 0 || trajectory.points.length === 0) {
    return {
      score: 0,
      accuracyScore: 0,
      continuityScore: 0,
      plausibilityScore: 0,
    };
  }

  // Mean accuracy over raw fixes that carry a valid (non-negative) estimate.
  const validAccuracies = raw
    .map((s) => s.horizontalAccuracy)
    .filter((a) => a >= 0);
  let accuracyScore: number;
  if (validAccuracies.length === 0) {
    accuracyScore = 0;
  } else {
    const mean = validAccuracies.reduce((a, b) => a + b, 0) /
      validAccuracies.length;
    accuracyScore = subScore(config.meanAccuracyCurve.valueAt(mean));
  }

  const gapSeconds = trajectory.gaps.reduce(
    (sum, gap) => sum + gapDuration(gap),
    0,
  );
  const duration = trajectoryDuration(trajectory);
  const gapFraction = duration > 0 ? gapSeconds / duration : 0;
  const continuityScore = subScore(
    config.gapFractionCurve.valueAt(gapFraction),
  );

  const rejectionRate = trajectory.rejectedSampleCount / raw.length;
  const plausibilityScore = subScore(
    config.rejectionRateCurve.valueAt(rejectionRate),
  );

  const weighted = accuracyScore * config.accuracyWeight +
    continuityScore * config.continuityWeight +
    plausibilityScore * config.plausibilityWeight;
  return {
    // Swift integer division on non-negative operands == Math.trunc.
    score: Math.trunc(weighted / 100),
    accuracyScore,
    continuityScore,
    plausibilityScore,
  };
}
