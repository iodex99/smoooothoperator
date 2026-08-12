import Foundation
import Testing
import SOCore
import SOTelemetry
@testable import SOSimulator

/// End-to-end proof that simulated telemetry exercises the REAL production
/// pipeline (spec §58): raw sensors → orientation calibration → vehicle
/// frames → trajectory → confidence → events, asserted against the
/// simulator's ground truth (spec §59 expectations).
@Suite("L1 pipeline integration")
struct PipelineIntegrationTests {
    let route = TelemetrySimulator.demoRoute(seed: 11)

    private func simulate(_ profile: SimulationProfile, seed: UInt64 = 99) -> SimulatedRun {
        TelemetrySimulator(profile: profile, seed: seed).simulate(route: route)
    }

    /// Runs the production pipeline exactly as the app will: interleaved
    /// ingestion by timestamp, then transform, reconstruct, assess, detect.
    private func runPipeline(_ run: SimulatedRun) -> (
        estimate: VehicleOrientationEstimate?,
        trajectory: ProcessedTrajectory,
        confidence: LocationConfidence,
        events: [DrivingEvent]
    ) {
        var estimator = VehicleOrientationEstimator()
        var gpsIndex = 0
        for imu in run.imu {
            while gpsIndex < run.gps.count && run.gps[gpsIndex].timestamp <= imu.timestamp {
                estimator.ingest(gps: run.gps[gpsIndex])
                gpsIndex += 1
            }
            estimator.ingest(imu: imu)
        }
        while gpsIndex < run.gps.count {
            estimator.ingest(gps: run.gps[gpsIndex])
            gpsIndex += 1
        }

        let trajectory = TrajectoryProcessor().process(run.gps)
        let confidence = LocationConfidenceScorer().assess(raw: run.gps, trajectory: trajectory)

        let estimate = estimator.estimate
        let vehicleFrames = estimate.map { estimate in run.imu.map { estimate.transform($0) } } ?? []
        let events = DrivingEventDetector().detect(samples: vehicleFrames, trajectory: trajectory)

        return (estimate, trajectory, confidence, events)
    }

    @Test("clean run: calibration recovers the actual mount, trajectory matches ground truth, confidence is high")
    func cleanRunEndToEnd() throws {
        let run = simulate(.fastSmooth)
        let result = runPipeline(run)

        // Orientation: the estimator must rediscover the simulator's mount.
        let estimate = try #require(result.estimate)
        #expect(estimate.forwardDevice.dot(run.groundTruth.mountForwardDevice) > 0.95)
        #expect(estimate.rightDevice.dot(run.groundTruth.mountRightDevice) > 0.95)
        #expect(estimate.upDevice.dot(run.groundTruth.mountUpDevice) > 0.95)
        #expect(estimate.confidence > 0.3)

        // Trajectory: distance within 5% of the route (correlated GPS noise
        // still inflates the reconstructed path slightly).
        let distanceError = abs(result.trajectory.totalDistanceMeters - run.groundTruth.routeDistanceMeters)
        #expect(distanceError / run.groundTruth.routeDistanceMeters < 0.05)
        #expect(result.trajectory.gaps.isEmpty)
        #expect(result.confidence.score >= 85)
    }

    @Test("spec §59: fast+smooth stays clean of hard events; fast+aggressive does not")
    func aggressionSeparation() {
        let hardKinds: Set<DrivingEventKind> = [.hardBraking, .hardCornering]

        let smoothEvents = runPipeline(simulate(.fastSmooth)).events
        let smoothHard = smoothEvents.filter { hardKinds.contains($0.kind) }
        #expect(smoothHard.isEmpty, "smooth driver should have zero hard events, got \(smoothHard.map(\.kind))")

        let aggressiveEvents = runPipeline(simulate(.fastAggressive)).events
        let aggressiveHard = aggressiveEvents.filter { hardKinds.contains($0.kind) }
        #expect(!aggressiveHard.isEmpty, "aggressive driver must trip hard events")
    }

    @Test("degraded GPS lowers location confidence below the clean baseline")
    func degradedConfidence() {
        let clean = runPipeline(simulate(.normal)).confidence.score
        let drifting = runPipeline(simulate(.gpsDrift)).confidence.score
        let jumping = runPipeline(simulate(.gpsJump)).confidence.score
        #expect(jumping < clean)
        #expect(drifting <= clean)
    }

    @Test("missing GPS windows surface as trajectory gaps and lower continuity")
    func missingGPSGaps() {
        let result = runPipeline(simulate(.missingGPS))
        #expect(!result.trajectory.gaps.isEmpty)
        let clean = runPipeline(simulate(.normal))
        #expect(result.confidence.continuityScore < clean.confidence.continuityScore)
    }

    @Test("mockGPS: position stream parses but the IMU is dead — the disagreement integrity will flag")
    func mockGPSDisagreement() throws {
        let run = simulate(.mockGPS)
        let trajectory = TrajectoryProcessor().process(run.gps)
        // GPS alone looks plausible (that's what makes mocking dangerous)…
        #expect(trajectory.totalDistanceMeters > 1000)

        // …but the phone never felt the drive: gravity-only IMU.
        let maxDynamics = run.imu.map {
            abs(Vector3(x: $0.accelX, y: $0.accelY, z: $0.accelZ).norm - 1)
        }.max() ?? 1
        #expect(maxDynamics < 0.01)

        // And the orientation estimator refuses to calibrate on it.
        var estimator = VehicleOrientationEstimator()
        var gpsIndex = 0
        for imu in run.imu {
            while gpsIndex < run.gps.count && run.gps[gpsIndex].timestamp <= imu.timestamp {
                estimator.ingest(gps: run.gps[gpsIndex])
                gpsIndex += 1
            }
            estimator.ingest(imu: imu)
        }
        #expect(estimator.estimate == nil)
    }

    @Test("teleporting fixes are rejected by the trajectory gate")
    func teleportRejection() {
        let run = simulate(.gpsJump)
        let trajectory = TrajectoryProcessor().process(run.gps)
        #expect(trajectory.rejectedSampleCount > 0)

        // Gate invariant: no kept pair may imply a speed above the gate —
        // whatever the raw stream contained.
        let config = TrajectoryProcessor().config
        for (a, b) in zip(trajectory.points, trajectory.points.dropFirst()) {
            let implied = a.coordinate.distance(to: b.coordinate) / (b.timestamp - a.timestamp)
            #expect(implied <= config.maxPlausibleSpeedMps + 0.001)
        }
        // Jump in/out excursions bound the distance inflation; the residual
        // (~2× offset per jump window) is for map matching to kill, not this
        // layer. It must stay bounded, not explode.
        let error = abs(trajectory.totalDistanceMeters - run.groundTruth.routeDistanceMeters)
        #expect(error / run.groundTruth.routeDistanceMeters < 0.25)
    }
}
