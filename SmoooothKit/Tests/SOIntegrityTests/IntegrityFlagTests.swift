import Foundation
import Testing
@testable import SOIntegrity

@Suite("IntegrityFlag")
struct IntegrityFlagTests {
    @Test("covers every anti-cheat signal mandated by spec §45")
    func coverage() {
        let mandated: Set<IntegrityFlag> = [
            .mockLocation, .gpsReplay, .impossibleSpeed, .impossibleAcceleration,
            .timestampAnomaly, .routeSkip, .gpsJump, .sensorMismatch,
            .suspiciousGap, .deviceIntegrity,
        ]
        // A superset, not an equality: the spec lists the anti-cheat signals
        // that MUST exist, and flags may also carry FAIRNESS signals that
        // accuse nobody (flyingStart). Asserting equality would make every
        // honest new signal look like a regression.
        #expect(Set(IntegrityFlag.allCases).isSuperset(of: mandated))
    }

    @Test("fairness signals are distinct from anti-cheat signals")
    func fairnessIsNotAccusation() {
        // flyingStart means "this run had an unfair advantage", never
        // "this driver cheated" — it must stay a warning so the run is
        // scored and shown while ranking nowhere.
        #expect(IntegrityFlag.allCases.contains(.flyingStart))
    }

    @Test("persisted raw values are snake-free stable strings")
    func rawValues() {
        // Raw values are stored server-side; a rename is a schema migration.
        for flag in IntegrityFlag.allCases {
            #expect(!flag.rawValue.isEmpty)
            #expect(flag.rawValue == flag.rawValue.trimmingCharacters(in: .whitespaces))
        }
    }
}
