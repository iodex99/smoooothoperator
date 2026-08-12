import Foundation
import Testing
@testable import SOCore

@Suite("GeoCoordinate")
struct GeoCoordinateTests {
    @Test("distance to self is zero")
    func distanceToSelf() {
        let point = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)  // Malibu
        #expect(point.distance(to: point) == 0)
    }

    @Test("one degree of latitude is ~111.2 km")
    func oneDegreeLatitude() {
        let a = GeoCoordinate(latitude: 0, longitude: 0)
        let b = GeoCoordinate(latitude: 1, longitude: 0)
        let expected = GeoCoordinate.earthRadiusMeters * .pi / 180
        #expect(abs(a.distance(to: b) - expected) < 0.001)
    }

    @Test("distance is symmetric")
    func symmetry() {
        let a = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
        let b = GeoCoordinate(latitude: 34.0522, longitude: -118.2437)  // LA
        #expect(a.distance(to: b) == b.distance(to: a))
    }

    @Test("Malibu to downtown LA is ~50 km")
    func knownDistance() {
        let malibu = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
        let la = GeoCoordinate(latitude: 34.0522, longitude: -118.2437)
        let distance = malibu.distance(to: la)
        #expect(distance > 45_000 && distance < 55_000)
    }

    @Test("Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let original = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeoCoordinate.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("SeededRandomNumberGenerator")
struct SeededRandomTests {
    @Test("same seed produces identical sequences")
    func determinism() {
        var a = SeededRandomNumberGenerator(seed: 42)
        var b = SeededRandomNumberGenerator(seed: 42)
        for _ in 0..<100 {
            #expect(a.next() == b.next())
        }
    }

    @Test("different seeds diverge")
    func seedSensitivity() {
        var a = SeededRandomNumberGenerator(seed: 42)
        var b = SeededRandomNumberGenerator(seed: 43)
        let aValues = (0..<10).map { _ in a.next() }
        let bValues = (0..<10).map { _ in b.next() }
        #expect(aValues != bValues)
    }
}
