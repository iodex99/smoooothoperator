import Foundation
import Testing
import SOCore
import SOCourse
import SOIntegrity
import SOModels
import SOTelemetry
@testable import SOSimulator

/// The L3 verdict matrix: every simulator profile through the FULL
/// production pipeline (trajectory → confidence → course tracking →
/// integrity) must land on its expected verdict (spec §§44–45, 58–59).
@Suite("Integrity verdict matrix")
struct IntegrityMatrixTests {
    let route = TelemetrySimulator.demoRoute(seed: 31)

    private func verdict(_ profile: SimulationProfile, seed: UInt64 = 3) -> IntegrityReport {
        let run = TelemetrySimulator(profile: profile, seed: seed).simulate(route: route)
        let trajectory = TrajectoryProcessor().process(run.gps)
        let confidence = LocationConfidenceScorer().assess(raw: run.gps, trajectory: trajectory)

        let gateIndexes = [0, route.count / 3, 2 * route.count / 3, route.count - 1]
        let checkpoints = gateIndexes.enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 40)
        }
        var tracker = CourseProgressTracker(polyline: route, checkpoints: checkpoints)!
        tracker.ingest(trajectory)

        return RunIntegrityEngine().evaluate(
            rawGPS: run.gps,
            rawIMU: run.imu,
            trajectory: trajectory,
            locationConfidence: confidence.score,
            routeAdherence: RouteAdherence(
                expectedGates: checkpoints.count,
                gatesHit: tracker.checkpointHits.count,
                deviationDetected: tracker.deviationDetected
            )
        )
    }

    // ── Clean profiles must verify — false accusations are product death ──

    @Test("clean driving styles verify",
          arguments: [SimulationProfile.fastSmooth, .fastAggressive, .slowSmooth, .normal])
    func cleanProfilesVerify(profile: SimulationProfile) {
        let report = verdict(profile)
        #expect(report.verdict == .verified,
                "expected verified, got \(report.verdict): \(report.findings)")
    }

    @Test("clean profiles never get flagged across seeds (false-positive property)",
          arguments: 1...6)
    func falsePositiveSweep(seed: Int) {
        for profile in [SimulationProfile.fastSmooth, .fastAggressive, .normal] {
            let report = verdict(profile, seed: UInt64(seed))
            #expect(report.verdict == .verified,
                    "\(profile) seed \(seed): \(report.findings)")
        }
    }

    // ── Cheat profiles must be invalid ────────────────────────────────────

    @Test("cheat profiles are invalid",
          arguments: [SimulationProfile.mockGPS, .impossiblePhysics, .timestampManipulation])
    func cheatProfilesInvalid(profile: SimulationProfile) {
        let report = verdict(profile)
        #expect(report.verdict == .invalid,
                "expected invalid, got \(report.verdict): \(report.findings)")
    }

    @Test("mockGPS is caught by combined signatures, not one lucky check")
    func mockGPSEvidence() {
        let report = verdict(.mockGPS)
        let mock = report.findings.first { $0.flag == .mockLocation && $0.severity == .critical }
        #expect(mock != nil)
        #expect((mock?.detail.contains("+")) == true)  // at least two joined signatures
    }

    // ── Degraded-but-honest profiles: questionable, never accused ─────────

    @Test("degraded-signal profiles rank nowhere but are not accused of cheating",
          arguments: [SimulationProfile.gpsJump, .missingGPS, .sensorDisagreement])
    func degradedProfilesQuestionable(profile: SimulationProfile) {
        let report = verdict(profile)
        // missingGPS may drop a whole gate window → routeSkip(critical) is a
        // defensible outcome; the others must stay questionable.
        if profile == .missingGPS {
            #expect(report.verdict != .verified)
        } else {
            #expect(report.verdict == .questionable,
                    "expected questionable, got \(report.verdict): \(report.findings)")
        }
    }

    @Test("route deviation invalidates the run (spec §78: won't appear on the leaderboard)")
    func routeDeviationInvalid() {
        let report = verdict(.routeDeviation)
        #expect(report.verdict == .invalid)
        #expect(report.findings.contains { $0.flag == .routeSkip })
    }

    @Test("gpsDrift is undetectable without map context in v1 — documented limitation")
    func gpsDriftLimitation() {
        // Slow correlated bias keeps every per-fix signal honest; verifying
        // is the correct v1 behavior (documented in ANTICHEAT.md). This test
        // pins the behavior so a future map-based check changes it on purpose.
        let report = verdict(.gpsDrift)
        #expect(report.verdict == .verified || report.verdict == .questionable)
    }
}
