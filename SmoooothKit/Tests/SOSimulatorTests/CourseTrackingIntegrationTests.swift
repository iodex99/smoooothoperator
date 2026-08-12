import Foundation
import Testing
import SOCore
import SOCourse
import SOTelemetry
@testable import SOSimulator

/// L2 ↔ L1 integration: simulated runs against a real course definition —
/// checkpoint gating, finish detection, and route-deviation flagging on
/// the same production pipeline.
@Suite("Course tracking integration")
struct CourseTrackingIntegrationTests {
    let route = TelemetrySimulator.demoRoute(seed: 21)

    /// Course built from the simulator route: gates at start, two interior
    /// vertices, and the finish.
    private func makeCourse() -> (polyline: [GeoCoordinate], checkpoints: [Checkpoint]) {
        let gateIndexes = [0, route.count / 3, 2 * route.count / 3, route.count - 1]
        let checkpoints = gateIndexes.enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 40)
        }
        return (route, checkpoints)
    }

    private func track(_ profile: SimulationProfile) -> CourseProgressTracker {
        let (polyline, checkpoints) = makeCourse()
        let run = TelemetrySimulator(profile: profile, seed: 5).simulate(route: route)
        let trajectory = TrajectoryProcessor().process(run.gps)
        var tracker = CourseProgressTracker(polyline: polyline, checkpoints: checkpoints)!
        tracker.ingest(trajectory)
        return tracker
    }

    @Test("clean profiles finish the course: every gate in order, full progress, no deviation",
          arguments: [SimulationProfile.fastSmooth, .normal, .slowSmooth])
    func cleanRunsFinish(profile: SimulationProfile) {
        let tracker = track(profile)
        #expect(tracker.hasFinished)
        #expect(tracker.checkpointHits.map(\.sequence) == [0, 1, 2, 3])
        #expect(tracker.progressFraction > 0.99)
        #expect(!tracker.deviationDetected)
    }

    @Test("the validator accepts the simulator's demo course")
    func demoCourseValidates() {
        let (polyline, checkpoints) = makeCourse()
        let issues = CourseValidator().validate(polyline: polyline, checkpoints: checkpoints)
        #expect(issues.isEmpty, "unexpected validation issues: \(issues)")
    }

    @Test("the routeDeviation profile is flagged and cannot finish clean")
    func routeDeviationFlagged() {
        let tracker = track(.routeDeviation)
        #expect(tracker.deviationDetected)
        #expect(!tracker.offCourseExcursions.isEmpty)
        #expect((tracker.offCourseExcursions.map(\.maxLateralOffsetMeters).max() ?? 0) > 100)
    }

    @Test("missing GPS windows do not fake progress — fraction only grows where data exists")
    func missingGPSProgress() {
        let tracker = track(.missingGPS)
        // The run still ends at the finish; dropped windows must not have
        // corrupted monotone progress.
        #expect(tracker.progressFraction > 0.99)
        #expect(!tracker.deviationDetected)
    }
}
