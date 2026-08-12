import SOCore
import SOModels

/// The versioned scoring configuration (spec §42). The canonical instance
/// lives in `configs/scoring/v1.json` at the repo root and is loaded by BOTH
/// this engine and the TypeScript server scorer — nothing scoring-related is
/// hard-coded anywhere.
///
/// Determinism contract (ADR-0002): every response is a `PiecewiseLinearCurve`
/// over plain arithmetic inputs; sub-scores are quantized to integer basis
/// points before any weighting; weighted combinations use exact integer math
/// with truncating division. The TS port mirrors each operation in order.
public struct ScoringConfig: Codable, Sendable, Equatable {
    /// Semver; stamped on every run as `scoringVersion` (spec §43).
    public var version: String
    /// Top-level category weights (35/35/20/10 in v1).
    public var weights: ScoringWeights

    public struct Pace: Codable, Sendable, Equatable {
        /// x = actualSeconds / benchmarkSeconds → y = pace bps.
        public var benchmarkRatioCurve: PiecewiseLinearCurve
    }

    public struct Smoothness: Codable, Sendable, Equatable {
        /// Severity weight per event kind (unitless), keyed by
        /// `DrivingEventKind.rawValue`.
        public var eventWeights: [String: Double]
        /// x = severity-weighted events per km → y = bps.
        public var weightedEventsPerKmCurve: PiecewiseLinearCurve
        /// x = RMS longitudinal jerk (g/s) over moving samples → y = bps.
        public var jerkRMSCurve: PiecewiseLinearCurve
        /// Integer bps weights of the two components; must sum to 10_000.
        public var eventComponentBps: Int
        public var jerkComponentBps: Int
    }

    public struct Control: Codable, Sendable, Equatable {
        /// x = std-dev of braking-family event peaks (g) → y = bps.
        public var brakingConsistencyCurve: PiecewiseLinearCurve
        /// x = std-dev of cornering-family event peaks (g) → y = bps.
        public var corneringConsistencyCurve: PiecewiseLinearCurve
        /// x = longitudinal sign flips per minute above the deadband → y = bps.
        public var oscillationRateCurve: PiecewiseLinearCurve
        /// |longitudinal| must exceed this (g) on both sides of a flip to count.
        public var oscillationDeadbandG: Double
        /// Integer bps weights of the three components; must sum to 10_000.
        public var brakingComponentBps: Int
        public var corneringComponentBps: Int
        public var oscillationComponentBps: Int
    }

    public struct Compliance: Codable, Sendable, Equatable {
        /// Speeding below this margin over the limit is measurement noise,
        /// m/s (never zero: GPS speed jitters).
        public var graceMps: Double
        /// x = exceedance index (distance-weighted relative overspeed) → y = bps.
        public var exceedanceCurve: PiecewiseLinearCurve
        /// Sub-score when no reliable speed-limit data exists — spec §41:
        /// never infer violations from insufficient data.
        public var noDataBps: Int
    }

    public var pace: Pace
    public var smoothness: Smoothness
    public var control: Control
    public var compliance: Compliance

    public init(
        version: String,
        weights: ScoringWeights,
        pace: Pace,
        smoothness: Smoothness,
        control: Control,
        compliance: Compliance
    ) {
        self.version = version
        self.weights = weights
        self.pace = pace
        self.smoothness = smoothness
        self.control = control
        self.compliance = compliance
    }

    /// Structural validity — checked at load time, never silently repaired.
    public var isValid: Bool {
        weights.isValid
            && smoothness.eventComponentBps >= 0 && smoothness.jerkComponentBps >= 0
            && smoothness.eventComponentBps + smoothness.jerkComponentBps == 10_000
            && control.brakingComponentBps >= 0 && control.corneringComponentBps >= 0
            && control.oscillationComponentBps >= 0
            && control.brakingComponentBps + control.corneringComponentBps
                + control.oscillationComponentBps == 10_000
            && (0...10_000).contains(compliance.noDataBps)
    }
}
