import CoreLocation

/// The system's last cached fix — no prompt, no updates started. Used only
/// as coarse context for Today's Challenge selection; real tracking lives
/// in SensorFeed and runs during challenges only (spec §62).
enum LastKnownLocation {
    static func coordinate() -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return manager.location?.coordinate
        default:
            return nil
        }
    }
}
