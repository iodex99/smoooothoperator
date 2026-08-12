import Foundation
import Testing
import SOCore
@testable import SOScoring

@Suite("RatingEngine")
struct RatingEngineTests {
    let engine = RatingEngine()

    private func runs(_ scores: [Int], difficulty: Int = 3) -> [RatingInput] {
        scores.map { RatingInput(finalScore: $0, courseDifficulty: difficulty) }
    }

    @Test("too few verified runs → unranked")
    func unranked() {
        #expect(engine.rating(from: runs([9000, 9100])) == .unranked)
        #expect(engine.rating(from: []) == .unranked)
    }

    @Test("consistent strong performance rates high")
    func strongConsistent() {
        let rating = engine.rating(from: runs([9400, 9450, 9420, 9380, 9410]))
        #expect(rating.value > 9200)
        #expect(rating.tier == "elite" || rating.tier == "legend")
    }

    @Test("inconsistency costs rating at equal mean")
    func inconsistencyPenalty() {
        let steady = engine.rating(from: runs([8800, 8800, 8800, 8800]))
        let erratic = engine.rating(from: runs([9800, 7800, 9800, 7800]))
        #expect(steady.value > erratic.value)
    }

    @Test("harder courses lift the rating, easier ones cap it")
    func difficultyWeighting() {
        let easy = engine.rating(from: runs([9000, 9000, 9000], difficulty: 1))
        let neutral = engine.rating(from: runs([9000, 9000, 9000], difficulty: 3))
        let hard = engine.rating(from: runs([9000, 9000, 9000], difficulty: 5))
        #expect(easy.value < neutral.value)
        #expect(hard.value >= neutral.value)  // capped at 10_000 per run
    }

    @Test("only the best window counts — grinding bad runs can't sink a rating")
    func bestWindow() {
        let good = runs(Array(repeating: 9200, count: 10))
        let withJunk = good + runs(Array(repeating: 4000, count: 20))
        let goodRating = engine.rating(from: good)
        let junkRating = engine.rating(from: withJunk)
        #expect(junkRating.value == goodRating.value)
    }

    @Test("tiers map thresholds correctly and ratings stay in bounds",
          arguments: 1...10)
    func boundsAndTiers(seed: Int) {
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
        let inputs = (0..<Int.random(in: 3...40, using: &rng)).map { _ in
            RatingInput(
                finalScore: Int.random(in: 0...10_000, using: &rng),
                courseDifficulty: Int.random(in: 1...5, using: &rng)
            )
        }
        let rating = engine.rating(from: inputs)
        #expect(rating.value >= 0 && rating.value <= 10_000)
        #expect(engine.config.tierNames.contains(rating.tier))
        #expect(rating.tier == engine.tier(for: rating.value))
    }

    @Test("default config is structurally valid")
    func configValid() {
        #expect(RatingConfig.default.isValid)
    }
}
