import Foundation

extension GeoCoordinate {
    /// Initial great-circle bearing toward `other`, in degrees from true
    /// north, normalized to 0..<360.
    public func bearing(to other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The coordinate reached by traveling `distanceMeters` along the
    /// great circle at `bearingDegrees`. Used by the simulator to integrate
    /// positions along a route.
    public func destination(bearingDegrees: Double, distanceMeters: Double) -> GeoCoordinate {
        let angular = distanceMeters / Self.earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180

        let lat2 = asin(
            sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing)
        )
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return GeoCoordinate(
            latitude: lat2 * 180 / .pi,
            longitude: (lon2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        )
    }
}
