import Testing
import SOModels
@testable import SOScoring

@Suite("ScoreBreakdown")
struct ScoreBreakdownTests {
    @Test("perfect sub-scores yield a perfect final score")
    func perfectScore() {
        let breakdown = ScoreBreakdown(paceBps: 10_000, smoothnessBps: 10_000, controlBps: 10_000, complianceBps: 10_000)
        #expect(breakdown.finalScore() == 10_000)
    }

    @Test("zero sub-scores yield zero")
    func zeroScore() {
        let breakdown = ScoreBreakdown(paceBps: 0, smoothnessBps: 0, controlBps: 0, complianceBps: 0)
        #expect(breakdown.finalScore() == 0)
    }

    @Test("known weighted combination is exact")
    func knownCombination() {
        // (9000×3500 + 9500×3500 + 8000×2000 + 10000×1000) / 10000 = 9075
        let breakdown = ScoreBreakdown(paceBps: 9000, smoothnessBps: 9500, controlBps: 8000, complianceBps: 10_000)
        #expect(breakdown.finalScore() == 9075)
    }

    @Test("custom valid weights are honored")
    func customWeights() {
        let equalWeights = ScoringWeights(paceBps: 2500, smoothnessBps: 2500, controlBps: 2500, complianceBps: 2500)
        let breakdown = ScoreBreakdown(paceBps: 8000, smoothnessBps: 6000, controlBps: 4000, complianceBps: 2000)
        #expect(breakdown.finalScore(weights: equalWeights) == 5000)
    }

    @Test("final score stays within bounds for boundary sub-scores",
          arguments: [0, 1, 4999, 5000, 9999, 10_000])
    func bounds(value: Int) {
        let breakdown = ScoreBreakdown(paceBps: value, smoothnessBps: value, controlBps: value, complianceBps: value)
        let final = breakdown.finalScore()
        #expect(final >= 0 && final <= 10_000)
        #expect(final == value)  // uniform sub-scores must pass through exactly
    }
}
