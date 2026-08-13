import SOModels

/// The four sub-scores of a run, each quantized to integer basis points
/// (0...10_000), plus the exact-integer weighted combination.
///
/// Quantizing *before* weighting is what makes the Swift reference scorer
/// and the TypeScript server port provably identical (cross-validated on
/// golden vectors) — floating point never touches the final score.
public struct ScoreBreakdown: Codable, Sendable, Equatable {
    public var paceBps: Int
    public var smoothnessBps: Int
    public var controlBps: Int
    public var complianceBps: Int

    public init(paceBps: Int, smoothnessBps: Int, controlBps: Int, complianceBps: Int) {
        self.paceBps = paceBps
        self.smoothnessBps = smoothnessBps
        self.controlBps = controlBps
        self.complianceBps = complianceBps
    }

    /// Final score in 0...10_000. Exact integer arithmetic, truncating division —
    /// the TypeScript port mirrors this operation order precisely.
    /// Invalid weights fall back to the shipped v1 defaults rather than
    /// trapping: this runs on the finish screen of a real drive, and a bad
    /// row in a server-side config table must never be able to crash the
    /// fleet mid-run. `ScoringConfig.load` rejects such configs at the
    /// boundary; this is the last line of defence.
    public func finalScore(weights: ScoringWeights = .v1Default) -> Int {
        let weights = weights.isValid ? weights : .v1Default
        let weighted =
            paceBps * weights.paceBps
            + smoothnessBps * weights.smoothnessBps
            + controlBps * weights.controlBps
            + complianceBps * weights.complianceBps
        return weighted / 10_000
    }
}
