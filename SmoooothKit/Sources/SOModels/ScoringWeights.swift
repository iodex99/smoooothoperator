/// Weighting of the four sub-scores in the final score, in integer basis
/// points (must sum to 10_000).
///
/// Integer bps everywhere is deliberate: the TypeScript scoring port must
/// produce bit-identical final scores, so all weighting math is exact
/// integer arithmetic — never floating point. See docs/SCORING.md.
public struct ScoringWeights: Codable, Sendable, Equatable {
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

    /// Spec §42 initial configuration: Pace 35%, Smoothness 35%, Control 20%, Compliance 10%.
    public static let v1Default = ScoringWeights(
        paceBps: 3500, smoothnessBps: 3500, controlBps: 2000, complianceBps: 1000
    )

    public var isValid: Bool {
        let parts = [paceBps, smoothnessBps, controlBps, complianceBps]
        return parts.allSatisfy { $0 >= 0 } && parts.reduce(0, +) == 10_000
    }
}
