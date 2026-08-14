// Ghost generation — TypeScript port of SmoooothKit SOGhost/GhostEngine
// (spec §§32-36). Ghosts are (progress, elapsed) pairs from the start-line
// crossing to the finish — never coordinates.

import type { Checkpoint, ProcessedTrajectory } from "./types.ts";
import type { GeoCoordinate } from "./geo.ts";
import { CourseProgressTracker } from "./course.ts";
import { distanceMeters } from "./geo.ts";

export interface GhostPoint {
  progress: number;
  elapsedSeconds: number;
}

export interface GhostTrajectory {
  points: GhostPoint[];
  totalSeconds: number;
}

export interface GhostConfig {
  progressResolution: number;
  requireFinished: boolean;
  /**
   * How far the car must move past the start gate before the clock starts.
   *
   * Mirrors Swift `GhostConfig.startMovingMeters`. This replaced a speed
   * threshold that the live clock applied to device-reported speed and the
   * ghost clock applied to smoothed derived speed — filtered derivatives
   * lag, so the two anchors landed ~2.6 s apart and a driver racing their
   * own best run beat themselves. Displacement does not lag.
   */
  startMovingMeters: number;
}

export const DEFAULT_GHOST_CONFIG: GhostConfig = {
  progressResolution: 0.005,
  requireFinished: true,
  startMovingMeters: 5,
};

/**
 * When the clock starts, given samples and the instant the start gate was
 * crossed. Mirrors Swift `GhostEngine.startTime` exactly — the live session
 * and ghost generation share one definition rather than two that resemble
 * each other.
 */
export function ghostStartTime(
  samples: { timestamp: number; coordinate: GeoCoordinate }[],
  gateHitTimestamp: number,
  movedMeters: number,
): number {
  const origin = samples.find((s) => s.timestamp >= gateHitTimestamp)?.coordinate;
  if (origin === undefined) return gateHitTimestamp;
  for (const sample of samples) {
    if (sample.timestamp < gateHitTimestamp) continue;
    if (distanceMeters(origin, sample.coordinate) >= movedMeters) {
      return sample.timestamp;
    }
  }
  // Never moved far enough — the gate hit is the only honest answer.
  return gateHitTimestamp;
}

/**
 * Mirrors Swift `GhostEngine.generate`. Returns null where Swift throws
 * (degenerate course / unfinished run / no start crossing) — the caller
 * simply skips ghost creation.
 */
export function generateGhost(
  trajectory: ProcessedTrajectory,
  polyline: GeoCoordinate[],
  checkpoints: Checkpoint[],
  config: GhostConfig = DEFAULT_GHOST_CONFIG,
): GhostTrajectory | null {
  const tracker = CourseProgressTracker.create(polyline, checkpoints);
  if (tracker === null) return null;

  const raw: {
    timestamp: number;
    progress: number;
    coordinate: GeoCoordinate;
  }[] = [];
  for (const point of trajectory.points) {
    tracker.ingestPoint(point);
    raw.push({
      timestamp: point.timestamp,
      progress: tracker.progressFraction,
      coordinate: point.coordinate,
    });
  }

  if (config.requireFinished && !tracker.hasFinished) return null;
  const startHit = tracker.checkpointHits.find((hit) => hit.sequence === 0);
  if (startHit === undefined) return null;

  const startTime = ghostStartTime(
    raw.map((sample) => ({
      timestamp: sample.timestamp,
      coordinate: sample.coordinate,
    })),
    startHit.timestamp,
    config.startMovingMeters,
  );

  const lastHit = tracker.checkpointHits[tracker.checkpointHits.length - 1];
  const finishTime = lastHit?.timestamp ??
    raw[raw.length - 1]?.timestamp ?? startTime;

  // The first point is the progress the car had AT the start instant, not a
  // forced zero — mirrors Swift. Pinning (0, 0) claimed the car was at the
  // start of the course when the clock started, but the clock starts once it
  // has moved `startMovingMeters` and it is already a little way along.
  let startProgress = 0;
  for (const sample of raw) {
    if (sample.timestamp <= startTime) startProgress = Math.min(1, sample.progress);
  }
  const points: GhostPoint[] = [{ progress: startProgress, elapsedSeconds: 0 }];
  let lastStoredProgress = startProgress;
  for (const sample of raw) {
    if (!(sample.timestamp > startTime && sample.timestamp <= finishTime)) {
      continue;
    }
    const progress = Math.min(1, sample.progress);
    if (!(progress >= lastStoredProgress + config.progressResolution)) {
      continue;
    }
    points.push({
      progress,
      elapsedSeconds: sample.timestamp - startTime,
    });
    lastStoredProgress = progress;
  }
  const totalSeconds = finishTime - startTime;
  // The final point is the progress the car ACTUALLY had at the finish gate,
  // not a forced 1.0 — mirrors Swift. A run ends on ENTERING the finish gate
  // circle, so the car is typically at ~0.986; pinning 1.0 stretched the last
  // segment across progress the driver never covers.
  let atFinish = 1;
  for (const sample of raw) {
    if (sample.timestamp <= finishTime) atFinish = Math.min(1, sample.progress);
  }
  const finishProgress = Math.min(
    1,
    Math.max(points[points.length - 1]?.progress ?? 0, atFinish),
  );
  if ((points[points.length - 1]?.progress ?? 0) < finishProgress) {
    points.push({ progress: finishProgress, elapsedSeconds: totalSeconds });
  }

  return { points, totalSeconds };
}
