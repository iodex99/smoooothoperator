import Foundation
import SOCore
import SOCourse
import SOGhost
import SOSimulator
import SOTelemetry

/// Emits the Swift ghost for each golden telemetry vector, so the
/// TypeScript port can be held to it.
///
/// The golden `expected.json` files carry scores, flags and verdicts — not
/// ghosts. That left `ghost.ts` cross-validated by NOTHING, on the one part
/// of the product that is the competitive moat, and three separate changes
/// were made to it in a single day with no check that the two sides still
/// agreed. A divergence there recreates the "racing yourself" defect on the
/// server only, where nobody sees it until a driver does.
///
/// Decoding goes through `GoldenVector`'s own Codable conformance rather
/// than re-reading the positional rows by hand — hand-mapping a format that
/// already has a decoder is how the two copies drift.
enum GhostXvalDump {
    static func emit(fixturesPath: String) -> String {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: fixturesPath)) ?? [])
            .filter { $0.hasSuffix(".telemetry.json") }
            .sorted()

        var out: [[String: Any]] = []
        for name in names {
            let url = URL(fileURLWithPath: fixturesPath).appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path),
                  let vector = try? JSONDecoder().decode(GoldenTelemetry.self, from: data)
            else { continue }

            let processed = TrajectoryProcessor().process(vector.gps)
            // Cheat and degraded profiles legitimately produce no ghost —
            // an unfinished run has none. Recorded as null so the TS side
            // must agree about THAT too, rather than skipping the case.
            let ghost = try? GhostEngine.generate(
                trajectory: processed,
                polyline: vector.route,
                checkpoints: vector.gates
            )
            if let ghost {
                out.append([
                    "vector": name,
                    "totalSeconds": ghost.totalSeconds,
                    "points": ghost.points.map {
                        ["progress": $0.progress, "elapsedSeconds": $0.elapsedSeconds]
                    },
                ])
            } else {
                out.append(["vector": name, "ghost": NSNull()])
            }
        }
        let data = try! JSONSerialization.data(
            withJSONObject: out, options: [.sortedKeys, .prettyPrinted]
        )
        return String(data: data, encoding: .utf8)!
    }
}
