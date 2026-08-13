import Foundation
import SOCore
import SOModels
import SOTelemetry
import Testing
@testable import SOScoring

/// Regression tests from the 2026-08-13 production-readiness audit. Every
/// case here was a real defect found by probing the engine with hostile or
/// degenerate input — the kind a hostile client, a corrupt server row, or a
/// bad GPS chip actually produces.
@Suite("Hostile input")
struct HostileInputTests {
    // MARK: - Remote-triggered crash (was: precondition failure)

    @Test("invalid scoring weights degrade instead of crashing the fleet")
    func invalidWeightsDoNotTrap() {
        let breakdown = ScoreBreakdown(
            paceBps: 9_000, smoothnessBps: 8_000,
            controlBps: 9_500, complianceBps: 10_000
        )
        // A config row whose weights don't sum to 10_000 used to hit a
        // `precondition` — SIGILL on every client, at the end of every drive,
        // triggerable by editing one server-side row.
        let broken = ScoringWeights(
            paceBps: 5_000, smoothnessBps: 5_000,
            controlBps: 5_000, complianceBps: 5_000
        )
        #expect(!broken.isValid)
        let score = breakdown.finalScore(weights: broken)
        #expect(score == breakdown.finalScore(weights: .v1Default))
        #expect((0...10_000).contains(score))
    }

    @Test("valid weights are still honored exactly")
    func validWeightsUnchanged() {
        let breakdown = ScoreBreakdown(
            paceBps: 10_000, smoothnessBps: 0,
            controlBps: 0, complianceBps: 0
        )
        // 35% of a perfect pace and nothing else.
        #expect(breakdown.finalScore(weights: .v1Default) == 3_500)
    }

    // MARK: - NaN / infinite telemetry

    @Test("a NaN fix is rejected, not kept — one bad sample can't void a run")
    func nanFixIsRejected() {
        let processor = TrajectoryProcessor()
        let base = 1_000.0
        var samples: [GPSSample] = []
        // A clean straight drive with a single NaN fix injected in the middle.
        for index in 0..<10 {
            let poisoned = index == 5
            samples.append(GPSSample(
                timestamp: base + Double(index),
                coordinate: GeoCoordinate(
                    latitude: poisoned ? Double.nan : 34.0 + Double(index) * 0.00018,
                    longitude: -118.0
                ),
                altitude: nil,
                horizontalAccuracy: 5,
                course: nil,
                speed: 20
            ))
        }
        let trajectory = processor.process(samples)
        #expect(trajectory.points.count == 9, "only the NaN fix is dropped")
        #expect(trajectory.points.allSatisfy { $0.coordinate.latitude.isFinite })
        #expect(
            trajectory.totalDistanceMeters > 0,
            "the drive still measures distance — the NaN used to zero it out"
        )
    }

    @Test("infinite timestamps and accuracies are rejected")
    func infiniteValuesRejected() {
        let processor = TrajectoryProcessor()
        let samples = [
            GPSSample(
                timestamp: .infinity,
                coordinate: GeoCoordinate(latitude: 34, longitude: -118),
                altitude: nil, horizontalAccuracy: 5, course: nil, speed: 10
            ),
            GPSSample(
                timestamp: 1_000,
                coordinate: GeoCoordinate(latitude: 34, longitude: -118),
                altitude: nil, horizontalAccuracy: .nan, course: nil, speed: 10
            ),
            GPSSample(
                timestamp: 1_001,
                coordinate: GeoCoordinate(latitude: 34.001, longitude: -118),
                altitude: nil, horizontalAccuracy: 5, course: nil, speed: 10
            ),
        ]
        let trajectory = processor.process(samples)
        #expect(trajectory.points.count == 1, "only the finite sample survives")
        #expect(trajectory.points[0].timestamp == 1_001)
    }
}
