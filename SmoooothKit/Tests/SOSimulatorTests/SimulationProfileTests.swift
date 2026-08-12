import Testing
@testable import SOSimulator

@Suite("SimulationProfile")
struct SimulationProfileTests {
    @Test("all twelve spec §58 profiles exist")
    func profileCount() {
        #expect(SimulationProfile.allCases.count == 12)
    }

    @Test("exactly the three cheating profiles are flagged as cheats")
    func cheatProfiles() {
        let cheats = SimulationProfile.allCases.filter(\.isCheatProfile)
        #expect(Set(cheats) == [.mockGPS, .impossiblePhysics, .timestampManipulation])
    }

    @Test("exactly the four degraded-signal profiles are flagged as degraded")
    func degradedProfiles() {
        let degraded = SimulationProfile.allCases.filter(\.isDegradedSignal)
        #expect(Set(degraded) == [.gpsDrift, .gpsJump, .missingGPS, .sensorDisagreement])
    }

    @Test("cheat and degraded categories never overlap")
    func categoriesDisjoint() {
        for profile in SimulationProfile.allCases {
            #expect(!(profile.isCheatProfile && profile.isDegradedSignal))
        }
    }

    @Test("raw values are unique (fixture filenames depend on them)")
    func uniqueRawValues() {
        let rawValues = SimulationProfile.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }
}
