import Foundation
import Testing
@testable import SOCore

@Suite("GeoCoordinate bearing/destination")
struct GeoBearingTests {
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)

    @Test("cardinal bearings", arguments: [
        (0.0, 0.001, 0.0),      // north: +lat
        (90.0, 0.0, 0.001),     // east:  +lon
        (180.0, -0.001, 0.0),   // south: -lat
        (270.0, 0.0, -0.001),   // west:  -lon
    ])
    func cardinal(expectedBearing: Double, dLat: Double, dLon: Double) {
        let target = GeoCoordinate(
            latitude: origin.latitude + dLat,
            longitude: origin.longitude + dLon
        )
        let bearing = origin.bearing(to: target)
        // Compare on the circle (359.9° ≈ 0°).
        let difference = abs(bearing - expectedBearing)
        let circular = min(difference, 360 - difference)
        #expect(circular < 0.1)
    }

    @Test("destination round-trips with distance and bearing",
          arguments: [0.0, 45.0, 137.0, 220.5, 359.0])
    func destinationRoundTrip(bearing: Double) {
        let distance = 500.0
        let target = origin.destination(bearingDegrees: bearing, distanceMeters: distance)
        #expect(abs(origin.distance(to: target) - distance) < 0.01)
        let measuredBearing = origin.bearing(to: target)
        let difference = abs(measuredBearing - bearing)
        let circular = min(difference, 360 - difference)
        #expect(circular < 0.01)
    }

    @Test("longitude stays normalized across the antimeridian")
    func antimeridian() {
        let nearDateline = GeoCoordinate(latitude: 0, longitude: 179.999)
        let east = nearDateline.destination(bearingDegrees: 90, distanceMeters: 1000)
        #expect(east.longitude >= -180 && east.longitude <= 180)
        #expect(east.longitude < 0)  // crossed to the western hemisphere
    }
}
