import Foundation
import Testing
import SOCore
import SOCourse
import SOScoring
import SOTelemetry
@testable import SOSimulator

/// Spec §59 — the synthetic competition. Full pipeline: simulate → calibrate
/// → transform → trajectory → events → score. The product's core promise
/// hangs on these orderings.
@Suite("Synthetic competition (spec §59)")
struct ScoringIntegrationTests {
    static let route = TelemetrySimulator.demoRoute(seed: 47)

    static let config: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    /// Benchmark: a strong reference time for this course (spec §57 —
    /// a REFERENCE BENCHMARK, never a fabricated user record).
    static let benchmarkSeconds: Double = {
        TelemetrySimulator(profile: .fastSmooth, seed: 100)
            .simulate(route: route).groundTruth.expectedDurationSeconds * 0.97
    }()

    private func scoreRun(_ profile: SimulationProfile, seed: UInt64 = 7) -> ScoreResult {
        let run = TelemetrySimulator(profile: profile, seed: seed).simulate(route: Self.route)

        var estimator = VehicleOrientationEstimator()
        var gpsIndex = 0
        for imu in run.imu {
            while gpsIndex < run.gps.count && run.gps[gpsIndex].timestamp <= imu.timestamp {
                estimator.ingest(gps: run.gps[gpsIndex])
                gpsIndex += 1
            }
            estimator.ingest(imu: imu)
        }
        let trajectory = TrajectoryProcessor().process(run.gps)
        let frames = estimator.estimate.map { estimate in run.imu.map { estimate.transform($0) } } ?? []
        let events = DrivingEventDetector().detect(samples: frames, trajectory: trajectory)

        return ScoringEngine(config: Self.config).score(
            trajectory: trajectory,
            events: events,
            vehicleFrames: frames,
            benchmarkSeconds: Self.benchmarkSeconds,
            speedLimits: []
        )
    }

    @Test("fast + smooth decisively beats fast + aggressive — smooth does not mean slow, fast does not mean reckless")
    func fastSmoothBeatsFastAggressive() {
        let smooth = scoreRun(.fastSmooth)
        let aggressive = scoreRun(.fastAggressive)

        #expect(smooth.finalScore > aggressive.finalScore,
                "smooth \(smooth.finalScore) vs aggressive \(aggressive.finalScore)")
        // The gap must come from smoothness/control, not pace.
        #expect(aggressive.breakdown.smoothnessBps < smooth.breakdown.smoothnessBps)
        #expect(aggressive.breakdown.paceBps >= smooth.breakdown.paceBps - 500)
    }

    @Test("slow + smooth does NOT automatically win — crawling every corner loses on pace")
    func slowSmoothDoesNotWin() {
        let fast = scoreRun(.fastSmooth)
        let slow = scoreRun(.slowSmooth)

        #expect(fast.finalScore > slow.finalScore,
                "fast \(fast.finalScore) vs slow \(slow.finalScore)")
        #expect(slow.breakdown.paceBps < fast.breakdown.paceBps)
        // Slow driving is genuinely smooth — it loses on pace alone.
        #expect(slow.breakdown.smoothnessBps >= 8000)
    }

    @Test("the full ordering holds: fastSmooth > normal > slowSmooth, and fastSmooth > fastAggressive")
    func fullOrdering() {
        let fastSmooth = scoreRun(.fastSmooth).finalScore
        let normal = scoreRun(.normal).finalScore
        let slowSmooth = scoreRun(.slowSmooth).finalScore
        let fastAggressive = scoreRun(.fastAggressive).finalScore

        #expect(fastSmooth > normal)
        #expect(normal > slowSmooth)
        #expect(fastSmooth > fastAggressive)
    }

    @Test("scores are stable across seeds — the ordering is systematic, not luck",
          arguments: 1...5)
    func orderingAcrossSeeds(seed: Int) {
        let smooth = scoreRun(.fastSmooth, seed: UInt64(seed))
        let aggressive = scoreRun(.fastAggressive, seed: UInt64(seed))
        #expect(smooth.finalScore > aggressive.finalScore,
                "seed \(seed): smooth \(smooth.finalScore) vs aggressive \(aggressive.finalScore)")
    }

    @Test("scoring the same run twice is byte-identical (determinism)")
    func deterministic() {
        #expect(scoreRun(.normal) == scoreRun(.normal))
    }
}
