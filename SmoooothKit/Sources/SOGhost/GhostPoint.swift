/// One sample of a normalized ghost trajectory.
///
/// Ghosts are distance-parameterized, not GPS-parameterized: `progress` is
/// the fraction of course distance completed (0...1) and `elapsedSeconds`
/// is time since run start. Raw GPS never leaves the owner's run — a ghost
/// exposes only competitive information (spec §§32, 35, 36).
public struct GhostPoint: Codable, Sendable, Equatable {
    /// Fraction of course distance completed, 0.0...1.0, strictly non-decreasing.
    public var progress: Double
    /// Seconds since the ghost's run started.
    public var elapsedSeconds: Double

    public init(progress: Double, elapsedSeconds: Double) {
        self.progress = progress
        self.elapsedSeconds = elapsedSeconds
    }
}
