import Foundation

/// Renders a distance in BOTH metric and imperial, always.
///
/// This exists because the app was showing the same course as "4.3 km" on
/// one screen and "2.7 mi" on another: one screen hard-coded a string while
/// the other called `Measurement.formatted`, which silently converts to the
/// device locale. Two numbers for one road is worse than either unit alone.
///
/// The rule now is that a distance is never shown in one system. A driver
/// who thinks in miles and a driver who thinks in kilometres are looking at
/// the same label, and neither has to convert anything. The locale only
/// decides which one is read first.
///
/// Deterministic and Foundation-locale-free on purpose — the same input
/// produces the same string on every device and on Linux, so it can be
/// tested here rather than only on a Mac.
public enum DistanceFormatter {
    public enum System: String, Sendable, Codable, CaseIterable {
        case metric
        case imperial
    }

    public static let metersPerMile = 1_609.344
    public static let metersPerFoot = 0.3048

    /// Both systems, the reader's own first. Returns "—" for anything that
    /// isn't a real distance rather than printing "nan km".
    public static func both(meters: Double, primary: System = .metric) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        let metric = self.metric(meters: meters)
        let imperial = self.imperial(meters: meters)
        return primary == .metric
            ? "\(metric) · \(imperial)"
            : "\(imperial) · \(metric)"
    }

    /// Metres under a kilometre, kilometres above it. Nobody describes a
    /// 600 m road as "0.6 km".
    public static func metric(meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        return "\(oneDecimal(meters / 1_000)) km"
    }

    /// Feet under a tenth of a mile, miles above it — the same reasoning.
    public static func imperial(meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        let miles = meters / metersPerMile
        if miles < 0.1 {
            return "\(Int((meters / metersPerFoot).rounded())) ft"
        }
        return "\(oneDecimal(miles)) mi"
    }

    /// One decimal place, rounded half-away-from-zero, without going through
    /// a locale-aware formatter — "4.3" everywhere, never "4,3".
    private static func oneDecimal(_ value: Double) -> String {
        let scaled = (value * 10).rounded()
        let whole = Int(scaled / 10)
        let fraction = Int(abs(scaled).truncatingRemainder(dividingBy: 10))
        return "\(whole).\(fraction)"
    }
}
