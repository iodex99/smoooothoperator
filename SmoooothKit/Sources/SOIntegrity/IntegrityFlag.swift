/// Individual anti-cheat / data-quality signals raised while analyzing a run.
/// The RunIntegrityEngine combines flags into a `RunVerificationStatus`.
/// Raw values are persisted server-side — never change them.
public enum IntegrityFlag: String, Codable, Sendable, CaseIterable {
    case mockLocation
    case gpsReplay
    case impossibleSpeed
    case impossibleAcceleration
    case timestampAnomaly
    case routeSkip
    case gpsJump
    case sensorMismatch
    case suspiciousGap
    case deviceIntegrity
    /// Crossed the start line already at speed. Not cheating — but a
    /// flying start is free pace, so the run cannot be ranked against
    /// drivers who launched from the line.
    case flyingStart

    /// The run was interrupted enough that its pace is not comparable.
    ///
    /// Pace is 35% of the score and is measured between two gates on a
    /// public road, so a driver who catches three red lights is scored
    /// against one who caught none as though they drove the same road. This
    /// is not cheating and is not treated as such — the run is kept, scored
    /// and shown, and ranked nowhere.
    case heavilyInterrupted
}
