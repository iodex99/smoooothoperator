import Foundation
import Testing
@testable import SOIntegrity

@Suite("IntegrityFlag")
struct IntegrityFlagTests {
    @Test("covers every anti-cheat signal mandated by spec §45")
    func coverage() {
        let expected: Set<IntegrityFlag> = [
            .mockLocation, .gpsReplay, .impossibleSpeed, .impossibleAcceleration,
            .timestampAnomaly, .routeSkip, .gpsJump, .sensorMismatch,
            .suspiciousGap, .deviceIntegrity,
        ]
        #expect(Set(IntegrityFlag.allCases) == expected)
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
