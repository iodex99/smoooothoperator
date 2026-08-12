import Foundation
import Testing
@testable import SOGhost

@Suite("GhostPoint")
struct GhostPointTests {
    @Test("Codable round-trip")
    func codable() throws {
        let point = GhostPoint(progress: 0.45, elapsedSeconds: 621.3)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(GhostPoint.self, from: data)
        #expect(decoded == point)
    }

    @Test("ghost payload exposes no location fields")
    func privacyShape() throws {
        // Spec §35/§36: a ghost is normalized progress + time only. If this
        // test fails, someone added a field — check it isn't raw GPS.
        let data = try JSONEncoder().encode(GhostPoint(progress: 0, elapsedSeconds: 0))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set((json ?? [:]).keys) == ["progress", "elapsedSeconds"])
    }
}
