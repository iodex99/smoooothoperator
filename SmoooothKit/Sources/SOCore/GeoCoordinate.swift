import Foundation

/// A WGS-84 latitude/longitude pair. The single geodesy primitive shared by
/// every engine; deliberately independent of CoreLocation so it exists on Linux.
public struct GeoCoordinate: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

extension GeoCoordinate {
    /// Mean Earth radius in meters (IUGG).
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance to `other` in meters (haversine).
    ///
    /// Adequate for course-scale distances (checkpoint radii, segment lengths);
    /// error vs. ellipsoidal methods is <0.5%, far below GPS noise.
    public func distance(to other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return Self.earthRadiusMeters * c
    }
}
