import Testing
import SOCore
@testable import SOCourse

@Suite("Checkpoint")
struct CheckpointTests {
    // ~50 m north of the checkpoint center (1° latitude ≈ 111,195 m).
    let center = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    var nearby: GeoCoordinate { GeoCoordinate(latitude: 34.0259 + 50.0 / 111_195, longitude: -118.7798) }
    var faraway: GeoCoordinate { GeoCoordinate(latitude: 34.0259 + 500.0 / 111_195, longitude: -118.7798) }

    @Test("contains its own center")
    func containsCenter() {
        let checkpoint = Checkpoint(sequence: 0, center: center, radiusMeters: 30)
        #expect(checkpoint.contains(center))
    }

    @Test("contains a point inside the radius")
    func containsInside() {
        let checkpoint = Checkpoint(sequence: 0, center: center, radiusMeters: 100)
        #expect(checkpoint.contains(nearby))
    }

    @Test("excludes a point outside the radius")
    func excludesOutside() {
        let checkpoint = Checkpoint(sequence: 0, center: center, radiusMeters: 100)
        #expect(!checkpoint.contains(faraway))
    }

    @Test("boundary behavior: point just inside a tight radius")
    func tightRadius() {
        let checkpoint = Checkpoint(sequence: 0, center: center, radiusMeters: 51)
        #expect(checkpoint.contains(nearby))
        let tighter = Checkpoint(sequence: 0, center: center, radiusMeters: 49)
        #expect(!tighter.contains(nearby))
    }
}
