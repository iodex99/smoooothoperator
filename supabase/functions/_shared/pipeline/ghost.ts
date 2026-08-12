// Ghost generation — TypeScript port of SmoooothKit SOGhost/GhostEngine
// (spec §§32-36). Ghosts are (progress, elapsed) pairs from the start-line
// crossing to the finish — never coordinates.

import type { Checkpoint, ProcessedTrajectory } from "./types.ts";
import type { GeoCoordinate } from "./geo.ts";
import { CourseProgressTracker } from "./course.ts";

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
  startMovingSpeedMps: number;
}

export const DEFAULT_GHOST_CONFIG: GhostConfig = {
  progressResolution: 0.005,
  requireFinished: true,
  startMovingSpeedMps: 1.5,
};

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

  const raw: { timestamp: number; progress: number; speedMps: number }[] = [];
  for (const point of trajectory.points) {
    tracker.ingestPoint(point);
    raw.push({
      timestamp: point.timestamp,
      progress: tracker.progressFraction,
      speedMps: point.speedMps,
    });
  }

  if (config.requireFinished && !tracker.hasFinished) return null;
  const startHit = tracker.checkpointHits.find((hit) => hit.sequence === 0);
  if (startHit === undefined) return null;

  const moving = raw.find(
    (sample) =>
      sample.timestamp >= startHit.timestamp &&
      sample.speedMps > config.startMovingSpeedMps,
  );
  const startTime = moving?.timestamp ?? startHit.timestamp;

  const lastHit = tracker.checkpointHits[tracker.checkpointHits.length - 1];
  const finishTime = lastHit?.timestamp ??
    raw[raw.length - 1]?.timestamp ?? startTime;

  const points: GhostPoint[] = [{ progress: 0, elapsedSeconds: 0 }];
  let lastStoredProgress = 0;
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
  if ((points[points.length - 1]?.progress ?? 0) < 1) {
    points.push({ progress: 1, elapsedSeconds: totalSeconds });
  }

  return { points, totalSeconds };
}
