import Foundation
import SOCore
import SOCourse

/// Emits a course proposal built from a synthetic drive, as the exact JSON
/// the app posts to `validate-course`.
///
/// This exists so the TypeScript side can be tested against what the Swift
/// side actually produces, rather than against a hand-written fixture that
/// drifts. The creation flow spans two languages; a contract nobody checks
/// is a contract that breaks on a real device.
enum CourseProposalDump {
    static func emit(metres: Double, curviness: Double, seed: UInt64) -> String {
        var rng = SeededRandomNumberGenerator(seed: seed)
        var points: [GeoCoordinate] = []
        let step = 2.0
        var lat = 34.0, lon = -118.0, heading = 0.0
        for index in 0..<max(Int(metres / step), 2) {
            heading += sin(Double(index) / 40.0) * curviness
            lat += cos(heading) * step / 111_320
            lon += sin(heading) * step / (111_320 * cos(lat * .pi / 180))
            let jitter = (Double.random(in: 0...1, using: &rng) - 0.5) * 6 / 111_320
            points.append(GeoCoordinate(latitude: lat + jitter, longitude: lon + jitter))
        }
        guard let proposal = CourseBuilder.build(from: points) else { return "{}" }
        let payload: [String: Any] = [
            "name": "Generated Course",
            "visibility": "public",
            "difficulty": 3,
            "polyline": proposal.polyline.map { [$0.latitude, $0.longitude] },
            "checkpoints": proposal.checkpoints.map {
                [Double($0.sequence), $0.center.latitude, $0.center.longitude, $0.radiusMeters]
            },
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]
        )
        return String(data: data, encoding: .utf8)!
    }
}
