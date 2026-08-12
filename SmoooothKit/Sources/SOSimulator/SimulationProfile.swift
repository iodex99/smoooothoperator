/// Every synthetic driving profile the telemetry simulator can produce
/// (spec §58). Each profile is simultaneously: a dev-mode data source, a
/// permanent test fixture, an anti-cheat validation case, and a Swift↔TS
/// cross-validation vector. All profiles feed the same production pipeline.
public enum SimulationProfile: String, Codable, Sendable, CaseIterable {
    // Driving styles
    case fastSmooth
    case fastAggressive
    case slowSmooth
    case normal

    // Degraded-signal conditions
    case gpsDrift
    case gpsJump
    case missingGPS
    case sensorDisagreement

    // Behavior anomalies
    case routeDeviation

    // Cheating attempts — must yield `.invalid` verification
    case mockGPS
    case impossiblePhysics
    case timestampManipulation

    /// Profiles that simulate deliberate cheating.
    public var isCheatProfile: Bool {
        switch self {
        case .mockGPS, .impossiblePhysics, .timestampManipulation: true
        default: false
        }
    }

    /// Profiles that simulate degraded (but honest) sensor conditions.
    public var isDegradedSignal: Bool {
        switch self {
        case .gpsDrift, .gpsJump, .missingGPS, .sensorDisagreement: true
        default: false
        }
    }
}
