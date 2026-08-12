import Foundation
import Testing
import SOCore
import SOTelemetry
@testable import SOCourse

@Suite("CourseProgressTracker")
struct CourseProgressTrackerTests {
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    let base = 1_754_982_000.0

    /// Straight 2 km course north with gates at 0 / 1000 / 2000.
    private func straightTracker() -> CourseProgressTracker {
        let polyline = stride(from: 0.0, through: 2000, by: 100).map {
            origin.destination(bearingDegrees: 0, distanceMeters: $0)
        }
        let gates = [0.0, 1000, 2000].enumerated().map { sequence, meters in
            Checkpoint(sequence: sequence,
                       center: origin.destination(bearingDegrees: 0, distanceMeters: meters),
                       radiusMeters: 30)
        }
        return CourseProgressTracker(polyline: polyline, checkpoints: gates)!
    }

    private func point(at meters: Double, lateral: Double = 0, time: Double) -> TrajectoryPoint {
        var coordinate = origin.destination(bearingDegrees: 0, distanceMeters: meters)
        if lateral != 0 {
            coordinate = coordinate.destination(bearingDegrees: 90, distanceMeters: lateral)
        }
        return TrajectoryPoint(
            timestamp: base + time,
            coordinate: coordinate,
            speedMps: 20,
            headingDegrees: 0,
            distanceAlongPathMeters: meters,
            horizontalAccuracy: 5
        )
    }

    @Test("clean drive: monotone progress, all gates hit in order, finished, no deviation")
    func cleanDrive() {
        var tracker = straightTracker()
        for step in 0...100 {
            let meters = Double(step) * 20
            tracker.ingest(point(at: meters, lateral: 2, time: Double(step)))
        }
        #expect(tracker.hasFinished)
        #expect(tracker.checkpointHits.map(\.sequence) == [0, 1, 2])
        #expect(zip(tracker.checkpointHits, tracker.checkpointHits.dropFirst())
            .allSatisfy { $0.timestamp < $1.timestamp })
        #expect(abs(tracker.progressFraction - 1) < 0.01)
        #expect(!tracker.deviationDetected)
        #expect(tracker.offCourseExcursions.isEmpty)
    }

    @Test("GPS jitter can match backward but reported progress never decreases")
    func monotoneProgress() {
        var tracker = straightTracker()
        tracker.ingest(point(at: 500, time: 0))
        let progressBefore = tracker.progressMeters
        tracker.ingest(point(at: 480, time: 1))  // noisy fix behind the cursor
        #expect(tracker.progressMeters >= progressBefore)
    }

    @Test("no progress accrues while off-course — corner cutting buys nothing")
    func offCourseNoProgress() {
        var tracker = straightTracker()
        tracker.ingest(point(at: 200, time: 0))
        let before = tracker.progressMeters
        // 300 m east of the course, walking "forward" along it.
        tracker.ingest(point(at: 600, lateral: 300, time: 1))
        tracker.ingest(point(at: 800, lateral: 300, time: 2))
        #expect(tracker.progressMeters == before)
        #expect(tracker.isOffCourse)
    }

    @Test("a long excursion is a route deviation; a brief one is forgiven")
    func deviationGrace() {
        var longExcursion = straightTracker()
        longExcursion.ingest(point(at: 100, time: 0))
        for second in 1...8 {  // 7s off-course > 5s grace
            longExcursion.ingest(point(at: 100 + Double(second) * 20, lateral: 100, time: Double(second)))
        }
        longExcursion.ingest(point(at: 300, time: 9))  // back on course
        #expect(longExcursion.deviationDetected)
        #expect(longExcursion.offCourseExcursions.count == 1)
        #expect((longExcursion.offCourseExcursions.first?.maxLateralOffsetMeters ?? 0) > 90)

        var briefExcursion = straightTracker()
        briefExcursion.ingest(point(at: 100, time: 0))
        briefExcursion.ingest(point(at: 120, lateral: 100, time: 1))
        briefExcursion.ingest(point(at: 140, lateral: 100, time: 2))
        briefExcursion.ingest(point(at: 160, time: 3))  // back within grace
        #expect(!briefExcursion.deviationDetected)
        #expect(briefExcursion.offCourseExcursions.count == 1)
    }

    @Test("a gate missed inside the corridor blocks finishing but is not a deviation")
    func missedGateInCorridor() {
        var tracker = straightTracker()
        for step in 0...100 {
            let meters = Double(step) * 20
            // Stay 35 m east around the middle gate: inside the 40 m corridor,
            // outside the 30 m gate radius.
            let nearMiddleGate = abs(meters - 1000) < 100
            tracker.ingest(point(at: meters, lateral: nearMiddleGate ? 35 : 0, time: Double(step)))
        }
        #expect(!tracker.hasFinished)
        #expect(tracker.checkpointHits.map(\.sequence) == [0])  // gate 1 missed → 2 can't count
        #expect(!tracker.deviationDetected)
        #expect(tracker.nextCheckpoint?.sequence == 1)
    }

    @Test("later gates entered out of order never count")
    func outOfOrderGates() {
        var tracker = straightTracker()
        tracker.ingest(point(at: 0, time: 0))          // gate 0 hit
        tracker.ingest(point(at: 2000, time: 1))       // jump straight to the finish gate
        #expect(tracker.checkpointHits.map(\.sequence) == [0])
        #expect(!tracker.hasFinished)
    }

    @Test("progressFraction is the normalized ghost axis")
    func progressFraction() {
        var tracker = straightTracker()
        // Drive continuously — the windowed matcher (rightly) refuses to
        // follow kilometer-sized teleports between fixes.
        for step in 0...25 {
            tracker.ingest(point(at: Double(step) * 20, time: Double(step)))
        }
        #expect(abs(tracker.progressFraction - 0.25) < 0.01)
        for step in 26...75 {
            tracker.ingest(point(at: Double(step) * 20, time: Double(step)))
        }
        #expect(abs(tracker.progressFraction - 0.75) < 0.01)
    }

    @Test("degenerate course geometry fails initialization")
    func degenerateInit() {
        #expect(CourseProgressTracker(polyline: [origin], checkpoints: []) == nil)
    }
}
