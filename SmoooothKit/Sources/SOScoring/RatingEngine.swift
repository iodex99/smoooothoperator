import Foundation
import SOCore
import SOModels

/// One verified run's contribution to a driver's rating.
public struct RatingInput: Codable, Sendable, Equatable {
    /// Authoritative final score, 0...10_000.
    public var finalScore: Int
    /// Course difficulty 1...5 (spec §23).
    public var courseDifficulty: Int

    public init(finalScore: Int, courseDifficulty: Int) {
        self.finalScore = finalScore
        self.courseDifficulty = courseDifficulty
    }
}

/// The driver's overall competitive rating (spec §49).
public struct SmoooothRating: Codable, Sendable, Equatable {
    /// 0...10_000, same scale as run scores.
    public var value: Int
    /// Display tier derived from `value` via config thresholds.
    public var tier: String

    public init(value: Int, tier: String) {
        self.value = value
        self.tier = tier
    }

    /// Below the minimum verified-run count.
    public static let unranked = SmoooothRating(value: 0, tier: "unranked")
}

/// Rating parameters. Deliberately simple (spec §49: "do not over-engineer");
/// the engine boundary exists so ELO/Glicko can replace the internals later
/// without touching callers.
public struct RatingConfig: Codable, Sendable, Equatable {
    /// Verified runs required before a rating exists.
    public var minVerifiedRuns: Int
    /// How many best difficulty-weighted scores count.
    public var bestRunsWindow: Int
    /// Difficulty (1...5) → multiplier in bps (10_000 = ×1).
    public var difficultyMultiplierCurve: PiecewiseLinearCurve
    /// Std-dev of counted scores → consistency penalty in rating points.
    public var inconsistencyPenaltyCurve: PiecewiseLinearCurve
    /// Ascending rating thresholds → tier names; the last tier whose
    /// threshold is ≤ value wins.
    public var tierThresholds: [Int]
    public var tierNames: [String]

    public init(
        minVerifiedRuns: Int,
        bestRunsWindow: Int,
        difficultyMultiplierCurve: PiecewiseLinearCurve,
        inconsistencyPenaltyCurve: PiecewiseLinearCurve,
        tierThresholds: [Int],
        tierNames: [String]
    ) {
        self.minVerifiedRuns = minVerifiedRuns
        self.bestRunsWindow = bestRunsWindow
        self.difficultyMultiplierCurve = difficultyMultiplierCurve
        self.inconsistencyPenaltyCurve = inconsistencyPenaltyCurve
        self.tierThresholds = tierThresholds
        self.tierNames = tierNames
    }

    public static let `default` = RatingConfig(
        minVerifiedRuns: 3,
        bestRunsWindow: 10,
        difficultyMultiplierCurve: PiecewiseLinearCurve(breakpoints: [
            .init(x: 1, y: 8500), .init(x: 3, y: 10_000), .init(x: 5, y: 11_500),
        ])!,
        inconsistencyPenaltyCurve: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 0), .init(x: 500, y: 150), .init(x: 1500, y: 600), .init(x: 3000, y: 1200),
        ])!,
        tierThresholds: [0, 5000, 6500, 7800, 8800, 9400],
        tierNames: ["rookie", "bronze", "silver", "gold", "elite", "legend"]
    )

    public var isValid: Bool {
        tierThresholds.count == tierNames.count
            && !tierThresholds.isEmpty
            && zip(tierThresholds, tierThresholds.dropFirst()).allSatisfy { $0 < $1 }
    }
}

/// Computes the Smooooth Rating from a driver's verified runs (spec §49):
/// difficulty-weighted best scores, penalized for inconsistency.
public struct RatingEngine: Sendable {
    public let config: RatingConfig

    public init(config: RatingConfig = .default) {
        self.config = config
    }

    public func rating(from runs: [RatingInput]) -> SmoooothRating {
        guard runs.count >= config.minVerifiedRuns else { return .unranked }

        // Difficulty-weighted scores, best window only. Integer math per the
        // determinism contract (the server recomputes ratings identically).
        let weighted = runs.map { run in
            let multiplier = Int(config.difficultyMultiplierCurve.value(at: Double(run.courseDifficulty)).rounded())
            return min(10_000, run.finalScore * multiplier / 10_000)
        }
        let counted = weighted.sorted(by: >).prefix(config.bestRunsWindow)

        let mean = counted.reduce(0, +) / counted.count
        let variance = counted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / counted.count
        let standardDeviation = Double(variance).squareRoot()
        let penalty = Int(config.inconsistencyPenaltyCurve.value(at: standardDeviation).rounded())

        let value = max(0, min(10_000, mean - penalty))
        return SmoooothRating(value: value, tier: tier(for: value))
    }

    public func tier(for value: Int) -> String {
        var name = config.tierNames.first ?? "unranked"
        for (threshold, tierName) in zip(config.tierThresholds, config.tierNames)
        where value >= threshold {
            name = tierName
        }
        return name
    }
}
