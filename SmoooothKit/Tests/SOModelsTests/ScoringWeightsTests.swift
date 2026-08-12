import Foundation
import Testing
@testable import SOModels

@Suite("ScoringWeights")
struct ScoringWeightsTests {
    @Test("v1 default matches spec §42 (35/35/20/10) and is valid")
    func v1Default() {
        let weights = ScoringWeights.v1Default
        #expect(weights.paceBps == 3500)
        #expect(weights.smoothnessBps == 3500)
        #expect(weights.controlBps == 2000)
        #expect(weights.complianceBps == 1000)
        #expect(weights.isValid)
    }

    @Test("weights not summing to 10_000 are invalid")
    func invalidSum() {
        let weights = ScoringWeights(paceBps: 3500, smoothnessBps: 3500, controlBps: 2000, complianceBps: 999)
        #expect(!weights.isValid)
    }

    @Test("negative weights are invalid even when the sum is 10_000")
    func negativeWeight() {
        let weights = ScoringWeights(paceBps: 11_000, smoothnessBps: -1000, controlBps: 0, complianceBps: 0)
        #expect(!weights.isValid)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let data = try JSONEncoder().encode(ScoringWeights.v1Default)
        let decoded = try JSONDecoder().decode(ScoringWeights.self, from: data)
        #expect(decoded == .v1Default)
    }
}

@Suite("RunVerificationStatus")
struct RunVerificationStatusTests {
    @Test("persisted raw values are stable")
    func rawValues() {
        // These strings live in the database and in golden fixtures.
        #expect(RunVerificationStatus.verified.rawValue == "verified")
        #expect(RunVerificationStatus.questionable.rawValue == "questionable")
        #expect(RunVerificationStatus.invalid.rawValue == "invalid")
        #expect(RunVerificationStatus.allCases.count == 3)
    }
}
