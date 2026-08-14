import SOCore
import SOTelemetry
import Testing
@testable import SOIntegrity

/// Start-line fairness (user directive 2026-08-13).
///
/// Pace is 35% of the score and is measured from the start gate, so the
/// speed you carry across that line is worth seconds no amount of skill can
/// recover. A driver launching from a standstill and one arriving at 100
/// km/h are not running the same race.
@Suite("Start line fairness")
struct StartLineTests {
    private let engine = RunIntegrityEngine()

    /// A short, unremarkable trajectory — the start-line check must not
    /// depend on anything else being wrong.
    private func cleanTrajectory() -> ProcessedTrajectory {
        let points = (0..<20).map { index in
            TrajectoryPoint(
                timestamp: 1_000 + Double(index),
                coordinate: GeoCoordinate(
                    latitude: 34.0 + Double(index) * 0.00018,
                    longitude: -118.0
                ),
                speedMps: 20,
                headingDegrees: 0,
                distanceAlongPathMeters: Double(index) * 20,
                horizontalAccuracy: 5
            )
        }
        // totalDistanceMeters and duration are derived, not stored.
        return ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0)
    }

    private func report(entrySpeed: Double?) -> IntegrityReport {
        engine.evaluate(
            rawGPS: [],
            rawIMU: [],
            trajectory: cleanTrajectory(),
            locationConfidence: nil,
            routeAdherence: nil,
            startEntrySpeedMps: entrySpeed
        )
    }

    @Test("a standing start is clean")
    func standingStart() {
        let result = report(entrySpeed: 0)
        #expect(!result.findings.contains { $0.flag == .flyingStart })
        #expect(result.verdict == .verified)
    }

    @Test("a slow roll-up is allowed — you cannot always stop on a public road")
    func slowRollUp() {
        // 7 m/s ≈ 25 km/h, under the 8 m/s ceiling.
        #expect(!report(entrySpeed: 7).findings.contains { $0.flag == .flyingStart })
    }

    @Test("a flying start is caught and cannot rank")
    func flyingStart() {
        // 28 m/s ≈ 100 km/h across the line.
        let result = report(entrySpeed: 28)
        #expect(result.findings.contains { $0.flag == .flyingStart })
        #expect(
            result.verdict == .questionable,
            "kept and scored, never ranked — it is unfairness, not fraud"
        )
    }

    @Test("the finding says what happened, in numbers")
    func findingCarriesEvidence() {
        let finding = report(entrySpeed: 28).findings.first { $0.flag == .flyingStart }
        #expect(finding?.detail.contains("28.0") == true)
        #expect(finding?.severity == .warning)
    }

    @Test("exactly at the ceiling is allowed; a hair over is not")
    func boundary() {
        #expect(!report(entrySpeed: 8).findings.contains { $0.flag == .flyingStart })
        #expect(report(entrySpeed: 8.01).findings.contains { $0.flag == .flyingStart })
    }

    @Test("an unknown crossing is not a finding")
    func unknownEntryIsSilent() {
        // A run that never crossed the start gate is caught by the route
        // checks; absence of data must not become an accusation here.
        #expect(!report(entrySpeed: nil).findings.contains { $0.flag == .flyingStart })
        #expect(!report(entrySpeed: .nan).findings.contains { $0.flag == .flyingStart })
        #expect(!report(entrySpeed: .infinity).findings.contains { $0.flag == .flyingStart })
    }

    @Test("the ceiling is configurable, like every other threshold")
    func configurable() {
        var config = IntegrityConfig.default
        config.maxStartEntrySpeedMps = 2
        let strict = RunIntegrityEngine(config: config).evaluate(
            rawGPS: [], rawIMU: [], trajectory: cleanTrajectory(),
            locationConfidence: nil, routeAdherence: nil,
            startEntrySpeedMps: 5
        )
        #expect(strict.findings.contains { $0.flag == .flyingStart })
    }
}
