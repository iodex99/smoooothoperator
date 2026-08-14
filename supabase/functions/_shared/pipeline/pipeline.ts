// Port of SmoooothKit SOSimulator/GoldenVector.swift `RunEvaluationPipeline`.
// The canonical evaluation order used everywhere a run is judged:
// orientation (interleaved GPS/IMU ingestion by timestamp) → vehicle frames →
// trajectory → confidence → course tracking → events → integrity → scoring.

import type { GeoCoordinate } from "./geo.ts";
import type {
  Checkpoint,
  DrivingEvent,
  GPSSample,
  IMUSample,
  ProcessedTrajectory,
  VehicleFrameSample,
} from "./types.ts";
import { processTrajectory } from "./trajectory.ts";
import {
  assessLocationConfidence,
  type LocationConfidence,
} from "./confidence.ts";
import { VehicleOrientationEstimator } from "./orientation.ts";
import { detectDrivingEvents } from "./events.ts";
import { CourseProgressTracker } from "./course.ts";
import { evaluateRunIntegrity, type IntegrityReport } from "./integrity.ts";
import { type ScoreResult, scoreRun, type ScoringConfig } from "./scoring.ts";

/** Everything the production pipeline concludes about one run. */
export interface PipelineOutcome {
  trajectory: ProcessedTrajectory;
  confidence: LocationConfidence;
  events: DrivingEvent[];
  integrity: IntegrityReport;
  score: ScoreResult;
  gatesHit: number;
  deviationDetected: boolean;
}

export interface PipelineInput {
  gps: GPSSample[];
  imu: IMUSample[];
  route: GeoCoordinate[];
  gates: Checkpoint[];
  benchmarkSeconds: number;
  scoringConfig: ScoringConfig;
}

/**
 * Evaluates one run. Returns null on degenerate course geometry — mirrors
 * Swift `RunEvaluationPipeline.evaluate`.
 */
export function evaluate(input: PipelineInput): PipelineOutcome | null {
  const { gps, imu, route, gates, benchmarkSeconds, scoringConfig } = input;

  const estimator = new VehicleOrientationEstimator();
  let gpsIndex = 0;
  for (const sample of imu) {
    while (
      gpsIndex < gps.length && gps[gpsIndex].timestamp <= sample.timestamp
    ) {
      estimator.ingestGPS(gps[gpsIndex]);
      gpsIndex += 1;
    }
    estimator.ingestIMU(sample);
  }
  while (gpsIndex < gps.length) {
    estimator.ingestGPS(gps[gpsIndex]);
    gpsIndex += 1;
  }

  const trajectory = processTrajectory(gps);
  const confidence = assessLocationConfidence(gps, trajectory);
  const estimate = estimator.estimate();
  const frames: VehicleFrameSample[] = estimate !== null
    ? imu.map((sample) => estimate.transform(sample))
    : [];
  const events = detectDrivingEvents(frames, trajectory);

  const tracker = CourseProgressTracker.create(route, gates);
  if (tracker === null) return null;
  tracker.ingestTrajectory(trajectory);

  // Speed at the START gate — mirrors RunEvaluationPipeline: the processed
  // trajectory point nearest the gate-0 hit.
  const startHit = tracker.checkpointHits.find((h) => h.sequence === 0) ?? null;
  let startEntrySpeedMps: number | null = null;
  if (startHit !== null && trajectory.points.length > 0) {
    let nearest = trajectory.points[0];
    for (const point of trajectory.points) {
      if (
        Math.abs(point.timestamp - startHit.timestamp) <
          Math.abs(nearest.timestamp - startHit.timestamp)
      ) {
        nearest = point;
      }
    }
    startEntrySpeedMps = nearest.speedMps;
  }

  const integrity = evaluateRunIntegrity(
    gps,
    imu,
    trajectory,
    confidence.score,
    {
      expectedGates: gates.length,
      gatesHit: tracker.checkpointHits.length,
      deviationDetected: tracker.deviationDetected,
    },
    undefined,
    startEntrySpeedMps,
  );

  const score = scoreRun(
    scoringConfig,
    trajectory,
    events,
    frames,
    benchmarkSeconds,
    [], // compliance no-data path — matches the Swift golden pipeline
  );

  return {
    trajectory,
    confidence,
    events,
    integrity,
    score,
    gatesHit: tracker.checkpointHits.length,
    deviationDetected: tracker.deviationDetected,
  };
}
