/// A piecewise-linear response curve defined by breakpoints, evaluated by
/// linear interpolation and clamped at both ends.
///
/// This is the ONLY nonlinearity permitted in scoring math (ADR-0002): it
/// keeps every computation inside `+ − × ÷`, which is bit-identical between
/// Swift `Double` and JavaScript `number`, so the TypeScript server scorer
/// can reproduce results exactly. Also used for speed-contextual event
/// thresholds (hard braking at 60 mph ≠ at 10 mph, spec §37).
public struct PiecewiseLinearCurve: Codable, Sendable, Equatable {
    /// One (x, y) breakpoint. x values must be strictly increasing.
    public struct Breakpoint: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public private(set) var breakpoints: [Breakpoint]

    /// Fails (returns nil) unless there are ≥1 breakpoints with strictly
    /// increasing x — an invalid curve is a config authoring error.
    public init?(breakpoints: [Breakpoint]) {
        guard !breakpoints.isEmpty else { return nil }
        for (previous, next) in zip(breakpoints, breakpoints.dropFirst()) where previous.x >= next.x {
            return nil
        }
        self.breakpoints = breakpoints
    }

    /// Evaluate at `x`: clamped to the first/last y outside the domain,
    /// linear interpolation between neighbors inside it.
    public func value(at x: Double) -> Double {
        guard let first = breakpoints.first, let last = breakpoints.last else {
            return 0  // unreachable: init guarantees non-empty
        }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }

        // Linear scan: curves have a handful of breakpoints; simplicity and
        // exact TS-port equivalence beat binary search here.
        for (lower, upper) in zip(breakpoints, breakpoints.dropFirst()) where x <= upper.x {
            let t = (x - lower.x) / (upper.x - lower.x)
            return lower.y + t * (upper.y - lower.y)
        }
        return last.y  // unreachable
    }
}
