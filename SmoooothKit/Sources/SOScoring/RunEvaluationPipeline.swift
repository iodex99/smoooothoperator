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

        let integrity = RunIntegrityEngine().evaluate(
            rawGPS: gps,
            rawIMU: imu,
            trajectory: trajectory,
            locationConfidence: confidence.score,
            routeAdherence: RouteAdherence(
                expectedGates: gates.count,
                gatesHit: tracker.checkpointHits.count,
                deviationDetected: tracker.deviationDetected
            )
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
