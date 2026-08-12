import SOCore

/// How trustworthy a run's location data is, on a 0...100 scale (spec §22).
/// Feeds run verification tiers and integrity checks — a beautiful score on
/// garbage GPS should never rank.
public struct LocationConfidence: Codable, Sendable, Equatable {
    /// Weighted overall confidence, 0...100.
    public var score: Int
    /// Sub-score from the mean horizontal accuracy of raw fixes, 0...100.
    public var accuracyScore: Int
    /// Sub-score from the fraction of the run covered by gaps, 0...100.
    public var continuityScore: Int
    /// Sub-score from the raw-sample rejection rate, 0...100.
    public var plausibilityScore: Int

    public init(score: Int, accuracyScore: Int, continuityScore: Int, plausibilityScore: Int) {
        self.score = score
        self.accuracyScore = accuracyScore
        self.continuityScore = continuityScore
        self.plausibilityScore = plausibilityScore
    }
}

/// Response curves and weights for `LocationConfidenceScorer`. Every mapping
/// is a `PiecewiseLinearCurve` (ADR-0002 — the only permitted nonlinearity)
/// so the TypeScript server port can reproduce scores exactly.
public struct LocationConfidenceConfig: Codable, Sendable, Equatable {
    /// Mean horizontal accuracy of valid raw fixes (meters, x) → 0...100 (y).
    public var meanAccuracyCurve: PiecewiseLinearCurve
    /// Fraction of the trajectory duration covered by gaps (0...1, x)
    /// → 0...100 (y).
    public var gapFractionCurve: PiecewiseLinearCurve
    /// Fraction of raw samples rejected by filtering (0...1, x) → 0...100 (y).
    public var rejectionRateCurve: PiecewiseLinearCurve
    /// Integer weight of the accuracy sub-score; the three weights must be
    /// non-negative and sum to 100.
    public var accuracyWeight: Int
    /// Integer weight of the continuity sub-score.
    public var continuityWeight: Int
    /// Integer weight of the plausibility sub-score.
    public var plausibilityWeight: Int

    public init(
        meanAccuracyCurve: PiecewiseLinearCurve,
        gapFractionCurve: PiecewiseLinearCurve,
        rejectionRateCurve: PiecewiseLinearCurve,
        accuracyWeight: Int,
        continuityWeight: Int,
        plausibilityWeight: Int
    ) {
        self.meanAccuracyCurve = meanAccuracyCurve
        self.gapFractionCurve = gapFractionCurve
        self.rejectionRateCurve = rejectionRateCurve
        self.accuracyWeight = accuracyWeight
        self.continuityWeight = continuityWeight
        self.plausibilityWeight = plausibilityWeight
    }

    /// Weights must be non-negative and sum to exactly 100 so the integer
    /// combination stays inside 0...100.
    public var weightsAreValid: Bool {
        let parts = [accuracyWeight, continuityWeight, plausibilityWeight]
        return parts.allSatisfy { $0 >= 0 } && parts.reduce(0, +) == 100
    }

    /// Spec §22 initial configuration. Breakpoint literals are strictly
    /// increasing in x, so the force-unwraps cannot fail.
    public static let `default` = LocationConfidenceConfig(
        meanAccuracyCurve: PiecewiseLinearCurve(breakpoints: [
            .init(x: 5, y: 100), .init(x: 10, y: 85), .init(x: 20, y: 55),
            .init(x: 30, y: 25), .init(x: 50, y: 0),
        ])!,
        gapFractionCurve: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 100), .init(x: 0.05, y: 85), .init(x: 0.15, y: 55),
            .init(x: 0.3, y: 25), .init(x: 0.6, y: 0),
        ])!,
        rejectionRateCurve: PiecewiseLinearCurve(breakpoints: [
            .init(x: 0, y: 100), .init(x: 0.02, y: 85), .init(x: 0.1, y: 50),
            .init(x: 0.3, y: 20), .init(x: 0.6, y: 0),
        ])!,
        accuracyWeight: 40,
        continuityWeight: 30,
        plausibilityWeight: 30
    )
}

/// Scores how much the location data of a run can be trusted, from the raw
/// samples plus the `ProcessedTrajectory` built from them (spec §22).
public struct LocationConfidenceScorer: Sendable {
    public let config: LocationConfidenceConfig

    public init(config: LocationConfidenceConfig = .default) {
        self.config = config
    }

    /// Assesses confidence for a run. `raw` must be the same samples that
    /// `trajectory` was processed from. Empty raw input or an empty
    /// trajectory yields all-zero confidence.
    ///
    /// Each sub-score is the config curve evaluated at its statistic,
    /// clamped to 0...100 and rounded to an integer *before* weighting —
    /// mirroring `ScoreBreakdown`: the final score is
    /// `sum(subScore × weight) / 100` in exact integer arithmetic.
    public func assess(raw: [GPSSample], trajectory: ProcessedTrajectory) -> LocationConfidence {
        precondition(config.weightsAreValid, "confidence weights must sum to 100")
        guard !raw.isEmpty, !trajectory.points.isEmpty else {
            return LocationConfidence(
                score: 0, accuracyScore: 0, continuityScore: 0, plausibilityScore: 0
            )
        }

        // Mean accuracy over raw fixes that carry a valid (non-negative)
        // estimate; invalid fixes are penalized via the rejection rate instead.
        let validAccuracies = raw.map(\.horizontalAccuracy).filter { $0 >= 0 }
        let accuracyScore: Int
        if validAccuracies.isEmpty {
            accuracyScore = 0
        } else {
            let mean = validAccuracies.reduce(0, +) / Double(validAccuracies.count)
            accuracyScore = Self.subScore(config.meanAccuracyCurve.value(at: mean))
        }

        let gapSeconds = trajectory.gaps.reduce(0) { $0 + $1.duration }
        let gapFraction = trajectory.duration > 0 ? gapSeconds / trajectory.duration : 0
        let continuityScore = Self.subScore(config.gapFractionCurve.value(at: gapFraction))

        let rejectionRate = Double(trajectory.rejectedSampleCount) / Double(raw.count)
        let plausibilityScore = Self.subScore(config.rejectionRateCurve.value(at: rejectionRate))

        let weighted =
            accuracyScore * config.accuracyWeight
            + continuityScore * config.continuityWeight
            + plausibilityScore * config.plausibilityWeight
        return LocationConfidence(
            score: weighted / 100,
            accuracyScore: accuracyScore,
            continuityScore: continuityScore,
            plausibilityScore: plausibilityScore
        )
    }

    /// Quantizes a curve output to an integer sub-score, clamped to 0...100
    /// so misauthored config curves can never push scores out of bounds.
    private static func subScore(_ curveValue: Double) -> Int {
        Int(min(100, max(0, curveValue)).rounded())
    }
}
