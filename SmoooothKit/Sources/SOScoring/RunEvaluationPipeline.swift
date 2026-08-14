import Foundation
import SOCore
import SOCourse
import SOIntegrity
import SOModels
import SOTelemetry

/// Everything the production pipeline concludes about one run. Shared by
/// sogen, the golden regression tests, and (in spirit) the server: the TS
/// implementation must reproduce `GoldenExpected` from the same telemetry.
public struct PipelineOutcome: Sendable {
    public var trajectory: ProcessedTrajectory
    public var confidence: LocationConfidence
    public var events: [DrivingEvent]
    public var integrity: IntegrityReport
    public var score: ScoreResult
    public var gatesHit: Int
    public var deviationDetected: Bool
}

/// The canonical evaluation order used everywhere a run is judged:
/// orientation (interleaved ingestion) → vehicle frames → trajectory →
/// confidence → course tracking → events → integrity → scoring.
public enum RunEvaluationPipeline {
    public static func evaluate(
        gps: [GPSSample],
        imu: [IMUSample],
        route: [GeoCoordinate],
        gates: [Checkpoint],
        benchmarkSeconds: Double,
        scoringConfig: ScoringConfig
    ) -> PipelineOutcome? {
        var estimator = VehicleOrientationEstimator()
        var gpsIndex = 0
        for sample in imu {
            while gpsIndex < gps.count && gps[gpsIndex].timestamp <= sample.timestamp {
                estimator.ingest(gps: gps[gpsIndex])
                gpsIndex += 1
            }
            estimator.ingest(imu: sample)
        }
        while gpsIndex < gps.count {
            estimator.ingest(gps: gps[gpsIndex])
            gpsIndex += 1
        }

        let trajectory = TrajectoryProcessor().process(gps)
        let confidence = LocationConfidenceScorer().assess(raw: gps, trajectory: trajectory)
        let frames = estimator.estimate.map { estimate in imu.map { estimate.transform($0) } } ?? []
        let events = DrivingEventDetector().detect(samples: frames, trajectory: trajectory)

        guard var tracker = CourseProgressTracker(polyline: route, checkpoints: gates) else {
            return nil
        }
        tracker.ingest(trajectory)

        // Speed as the driver crossed the START gate — the fairness signal
        // for pace. Taken from the processed trajectory point nearest the
        // gate-0 hit, so it is the same number the server recomputes.
        let startEntrySpeed: Double? = tracker.checkpointHits
            .first(where: { $0.sequence == 0 })
            .flatMap { hit in
                trajectory.points
                    .min(by: {
                        abs($0.timestamp - hit.timestamp) < abs($1.timestamp - hit.timestamp)
                    })?
                    .speedMps
            }

        let integrity = RunIntegrityEngine().evaluate(
            rawGPS: gps,
            rawIMU: imu,
            trajectory: trajectory,
            locationConfidence: confidence.score,
            routeAdherence: RouteAdherence(
                expectedGates: gates.count,
                gatesHit: tracker.checkpointHits.count,
                deviationDetected: tracker.deviationDetected
            ),
            startEntrySpeedMps: startEntrySpeed,
            // The window the run is actually scored over. Outside it the car
            // is staging, and staging is not traffic.
            scoredFrom: tracker.checkpointHits.first(where: { $0.sequence == 0 })?.timestamp,
            scoredUntil: tracker.checkpointHits.last?.timestamp
        )

        let score = ScoringEngine(config: scoringConfig).score(
            trajectory: trajectory,
            events: events,
            vehicleFrames: frames,
            benchmarkSeconds: benchmarkSeconds,
            speedLimits: []
        )

        return PipelineOutcome(
            trajectory: trajectory,
            confidence: confidence,
            events: events,
            integrity: integrity,
            score: score,
            gatesHit: tracker.checkpointHits.count,
            deviationDetected: tracker.deviationDetected
        )
    }
}
