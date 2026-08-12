// Port of SmoooothKit SOTelemetry/TrajectoryProcessor.swift.
// The three gates run in order (accuracy → monotonic timestamp → teleport)
// and each rejection `continue`s — iteration and guard order preserved exactly.

import { bearingDegrees, distanceMeters } from "./geo.ts";
import type {
  GPSSample,
  ProcessedTrajectory,
  TelemetryGap,
  TrajectoryPoint,
} from "./types.ts";

/** Filtering and reconstruction thresholds (spec §21). */
export interface TrajectoryConfig {
  maxHorizontalAccuracyMeters: number;
  maxPlausibleSpeedMps: number;
  gapThresholdSeconds: number;
  minMovingSpeedMps: number;
}

/** Spec §21 initial thresholds — mirrors Swift `TrajectoryConfig.default`. */
export const DEFAULT_TRAJECTORY_CONFIG: TrajectoryConfig = {
  maxHorizontalAccuracyMeters: 30,
  maxPlausibleSpeedMps: 90,
  gapThresholdSeconds: 3,
  minMovingSpeedMps: 1,
};

/**
 * Rebuilds a clean trajectory from raw GPS samples. Output timestamps are
 * strictly increasing and distanceAlongPathMeters is non-decreasing.
 */
export function processTrajectory(
  samples: readonly GPSSample[],
  config: TrajectoryConfig = DEFAULT_TRAJECTORY_CONFIG,
): ProcessedTrajectory {
  const points: TrajectoryPoint[] = [];
  const gaps: TelemetryGap[] = [];
  let rejectedCount = 0;
  // Rejections since the last kept point, used to attribute gap reason.
  let rejectedSinceLastKept = 0;

  for (const sample of samples) {
    // Gate 1 — accuracy: negative means invalid fix, large means noise.
    if (
      !(sample.horizontalAccuracy >= 0 &&
        sample.horizontalAccuracy <= config.maxHorizontalAccuracyMeters)
    ) {
      rejectedCount += 1;
      rejectedSinceLastKept += 1;
      continue;
    }

    if (points.length === 0) {
      // First kept point: nothing to derive against.
      const speed = sample.speed !== null && sample.speed >= 0
        ? Math.max(0, sample.speed)
        : 0;
      points.push({
        timestamp: sample.timestamp,
        coordinate: sample.coordinate,
        speedMps: speed,
        headingDegrees: sample.course,
        distanceAlongPathMeters: 0,
        horizontalAccuracy: sample.horizontalAccuracy,
      });
      rejectedSinceLastKept = 0;
      continue;
    }
    const previous = points[points.length - 1];

    // Gate 2 — monotonic time: on regression or duplicate, the earliest
    // arrival (already kept) wins.
    const dt = sample.timestamp - previous.timestamp;
    if (!(dt > 0)) {
      rejectedCount += 1;
      rejectedSinceLastKept += 1;
      continue;
    }

    // Gate 3 — teleport: implied straight-line speed from the previous kept
    // point must stay physically plausible.
    const stepMeters = distanceMeters(previous.coordinate, sample.coordinate);
    const impliedSpeed = stepMeters / dt;
    if (!(impliedSpeed <= config.maxPlausibleSpeedMps)) {
      rejectedCount += 1;
      rejectedSinceLastKept += 1;
      continue;
    }

    const speed = sample.speed !== null && sample.speed >= 0
      ? Math.max(0, sample.speed)
      : Math.max(0, impliedSpeed);

    let heading: number | null;
    if (sample.course !== null) {
      heading = sample.course;
    } else if (speed > config.minMovingSpeedMps) {
      heading = bearingDegrees(previous.coordinate, sample.coordinate);
    } else {
      heading = null;
    }

    if (dt > config.gapThresholdSeconds) {
      gaps.push({
        startTime: previous.timestamp,
        endTime: sample.timestamp,
        reason: rejectedSinceLastKept > 0 ? "rejectedSamples" : "noSamples",
      });
    }

    points.push({
      timestamp: sample.timestamp,
      coordinate: sample.coordinate,
      speedMps: speed,
      headingDegrees: heading,
      distanceAlongPathMeters: previous.distanceAlongPathMeters + stepMeters,
      horizontalAccuracy: sample.horizontalAccuracy,
    });
    rejectedSinceLastKept = 0;
  }

  return { points, gaps, rejectedSampleCount: rejectedCount };
}
