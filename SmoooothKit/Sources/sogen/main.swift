// sogen — Smooooth Operator development CLI.
//
// Generates golden telemetry vectors and runs the production pipeline over
// them. Goldens anchor Swift regression tests AND the Swift↔TypeScript
// scoring cross-validation (ADR-0002): both implementations must reproduce
// each vector's expected.json exactly.

import Foundation
import SOCore
import SOScoring
import SOSimulator

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)  // EX_USAGE
}

func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func loadScoringConfig(from path: String) -> ScoringConfig {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("sogen: cannot read scoring config at \(path)")
    }
    do {
        return try ScoringConfig.load(from: data)
    } catch {
        fail("sogen: invalid scoring config at \(path): \(error)")
    }
}

func writeJSON<Value: Encodable>(_ value: Value, to path: String, pretty: Bool) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("sogen: failed writing \(path): \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "version", "--version":
    print("sogen \(KitInfo.version)")

case "goldens":
    // sogen goldens --out fixtures/golden --config configs/scoring/v1.json [--seed 1]
    guard let outDir = argumentValue("--out", in: arguments) else {
        fail("sogen goldens: --out <dir> is required")
    }
    let configPath = argumentValue("--config", in: arguments) ?? "configs/scoring/v1.json"
    let seed = UInt64(argumentValue("--seed", in: arguments) ?? "1") ?? 1
    let scoringConfig = loadScoringConfig(from: configPath)

    try? FileManager.default.createDirectory(
        atPath: outDir, withIntermediateDirectories: true
    )
    for profile in SimulationProfile.allCases {
        do {
            let (telemetry, expected) = try GoldenVectorFactory.make(
                profile: profile, seed: seed, scoringConfig: scoringConfig
            )
            let stem = "\(outDir)/\(profile.rawValue)_\(seed)"
            writeJSON(telemetry, to: "\(stem).telemetry.json", pretty: false)
            writeJSON(expected, to: "\(stem).expected.json", pretty: true)
            print("\(profile.rawValue)_\(seed): score \(expected.finalScore), verdict \(expected.verdict)")
        } catch {
            fail("sogen goldens: \(profile.rawValue) failed: \(error)")
        }
    }

case "score":
    // sogen score --input <telemetry.json> [--config path] [--out expected.json]
    guard let inputPath = argumentValue("--input", in: arguments) else {
        fail("sogen score: --input <telemetry.json> is required")
    }
    let configPath = argumentValue("--config", in: arguments) ?? "configs/scoring/v1.json"
    let scoringConfig = loadScoringConfig(from: configPath)
    guard let data = FileManager.default.contents(atPath: inputPath) else {
        fail("sogen score: cannot read \(inputPath)")
    }
    do {
        let telemetry = try JSONDecoder().decode(GoldenTelemetry.self, from: data)
        guard let outcome = RunEvaluationPipeline.evaluate(
            gps: telemetry.gps,
            imu: telemetry.imu,
            route: telemetry.route,
            gates: telemetry.gates,
            benchmarkSeconds: telemetry.benchmarkSeconds,
            scoringConfig: scoringConfig
        ) else {
            fail("sogen score: degenerate course in \(inputPath)")
        }
        let expected = GoldenExpected(outcome: outcome)
        if let outPath = argumentValue("--out", in: arguments) {
            writeJSON(expected, to: outPath, pretty: true)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            print(String(data: try encoder.encode(expected), encoding: .utf8) ?? "")
        }
    } catch {
        fail("sogen score: \(error)")
    }

case "benchmark":
    // sogen benchmark --input route.json
    // route.json: [[lat, lon], ...] — real road geometry.
    // Emits the course reference benchmark (spec §57): a strong smooth
    // driver simulated over the actual geometry, tightened 3% — clearly a
    // REFERENCE BENCHMARK, never a fabricated human record.
    guard let inputPath = argumentValue("--input", in: arguments) else {
        fail("sogen benchmark: --input <route.json> is required")
    }
    guard let data = FileManager.default.contents(atPath: inputPath) else {
        fail("sogen benchmark: cannot read \(inputPath)")
    }
    do {
        let pairs = try JSONDecoder().decode([[Double]].self, from: data)
        let route = pairs.map { GeoCoordinate(latitude: $0[0], longitude: $0[1]) }
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 100).simulate(route: route)
        guard run.groundTruth.routeDistanceMeters > 0 else {
            fail("sogen benchmark: degenerate route in \(inputPath)")
        }
        let benchmark = (run.groundTruth.expectedDurationSeconds * 0.97).rounded()
        print(
            """
            {"benchmarkSeconds": \(Int(benchmark)), "distanceMeters": \(Int(run.groundTruth.routeDistanceMeters.rounded()))}
            """
        )
    } catch {
        fail("sogen benchmark: \(error)")
    }

case nil, "help", "--help":
    print(
        """
        sogen \(KitInfo.version) — Smooooth Operator development CLI

        USAGE: sogen <subcommand> [options]

        SUBCOMMANDS:
          goldens --out <dir> [--config <path>] [--seed <n>]
              Regenerate all golden vectors (one per simulation profile):
              <profile>_<seed>.telemetry.json + .expected.json.
          score --input <telemetry.json> [--config <path>] [--out <path>]
              Run the production pipeline over a telemetry vector and emit
              its expected.json.
          version
              Print the SmoooothKit version.
        """
    )

default:
    fail("sogen: unknown subcommand '\(arguments.first!)' — run 'sogen help'")
}
