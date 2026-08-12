import Foundation
import Testing
import SOCore
@testable import SOTelemetry

@Suite("Telemetry samples")
struct SamplesTests {
    @Test("GPSSample Codable round-trip preserves all fields including nils")
    func gpsRoundTrip() throws {
        let sample = GPSSample(
            timestamp: 1_754_982_000.5,
            coordinate: GeoCoordinate(latitude: 34.0259, longitude: -118.7798),
            altitude: nil,
            horizontalAccuracy: 4.2,
            course: 187.5,
            speed: 17.9
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(GPSSample.self, from: data)
        #expect(decoded == sample)
        #expect(decoded.altitude == nil)
    }

    @Test("IMUSample Codable round-trip")
    func imuRoundTrip() throws {
        let sample = IMUSample(
            timestamp: 1_754_982_000.52,
            accelX: 0.012, accelY: -0.34, accelZ: 0.98,
            gyroX: 0.001, gyroY: 0.02, gyroZ: -0.005
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(IMUSample.self, from: data)
        #expect(decoded == sample)
    }
}
