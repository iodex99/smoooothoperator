import Foundation
import Testing
import SOScoring
@testable import SOSimulator

/// Golden-vector regression: the committed fixtures in `fixtures/golden/`
/// pin the entire pipeline's behavior. Any change to simulator, filters,
/// events, integrity, or scoring that shifts an output must arrive with a
/// deliberate `make regen-goldens` and a reviewed diff (never silently).
/// The TypeScript server implementation must reproduce the same
/// expected.json from the same telemetry.json (xval, ADR-0002).
@Suite("Golden vectors")
struct GoldenVectorTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let goldenDirectory = repoRoot.appendingPathComponent("fixtures/golden")

    static let scoringConfig = try! ScoringConfig.load(
        from: Data(contentsOf: repoRoot.appendingPathComponent("configs/scoring/v1.json"))
    )

    @Test("every committed golden vector reproduces its expected output",
          arguments: SimulationProfile.allCases)
    func pipelineReproducesExpected(profile: SimulationProfile) throws {
        let stem = Self.goldenDirectory.appendingPathComponent("\(profile.rawValue)_1")
        let telemetry = try JSONDecoder().decode(
            GoldenTelemetry.self,
            from: Data(contentsOf: stem.appendingPathExtension("telemetry.json"))
        )
        let committed = try JSONDecoder().decode(
            GoldenExpected.self,
            from: Data(contentsOf: stem.appendingPathExtension("expected.json"))
        )

        let outcome = try #require(RunEvaluationPipeline.evaluate(
            gps: telemetry.gps,
            imu: telemetry.imu,
            route: telemetry.route,
            gates: telemetry.gates,
            benchmarkSeconds: telemetry.benchmarkSeconds,
            scoringConfig: Self.scoringConfig
        ))
        #expect(GoldenExpected(outcome: outcome) == committed)
    }

    @Test("regenerating from (profile, seed) matches the committed telemetry — simulator drift requires a deliberate regen",
          arguments: [SimulationProfile.fastSmooth, .mockGPS, .routeDeviation])
    func simulatorMatchesCommitted(profile: SimulationProfile) throws {
        let stem = Self.goldenDirectory.appendingPathComponent("\(profile.rawValue)_1")
        let committed = try JSONDecoder().decode(
            GoldenTelemetry.self,
            from: Data(contentsOf: stem.appendingPathExtension("telemetry.json"))
        )
        let regenerated = try GoldenVectorFactory.make(
            profile: profile, seed: 1, scoringConfig: Self.scoringConfig
        ).telemetry
        #expect(regenerated == committed)
    }

    @Test("the golden matrix covers every verdict tier")
    func verdictCoverage() throws {
        var verdicts = Set<String>()
        for profile in SimulationProfile.allCases {
            let stem = Self.goldenDirectory.appendingPathComponent("\(profile.rawValue)_1")
            let expected = try JSONDecoder().decode(
                GoldenExpected.self,
                from: Data(contentsOf: stem.appendingPathExtension("expected.json"))
            )
            verdicts.insert(expected.verdict)
        }
        #expect(verdicts == ["verified", "questionable", "invalid"])
    }
}
