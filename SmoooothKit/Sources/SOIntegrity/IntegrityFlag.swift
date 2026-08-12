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
}
