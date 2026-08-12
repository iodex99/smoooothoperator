import Foundation
import Testing
@testable import SOCore

@Suite("Vector3")
struct Vector3Tests {
    @Test("dot product of orthogonal unit vectors is zero")
    func orthogonalDot() {
        let x = Vector3(x: 1, y: 0, z: 0)
        let y = Vector3(x: 0, y: 1, z: 0)
        #expect(x.dot(y) == 0)
    }

    @Test("cross product follows the right-hand rule: x × y = z")
    func rightHandRule() {
        let x = Vector3(x: 1, y: 0, z: 0)
        let y = Vector3(x: 0, y: 1, z: 0)
        #expect(x.cross(y) == Vector3(x: 0, y: 0, z: 1))
        #expect(y.cross(x) == Vector3(x: 0, y: 0, z: -1))
    }

    @Test("norm of a 3-4-0 vector is 5")
    func norm() {
        #expect(Vector3(x: 3, y: 4, z: 0).norm == 5)
    }

    @Test("normalized returns a unit vector preserving direction")
    func normalized() throws {
        let vector = Vector3(x: 0, y: 0, z: -9.81)
        let unit = try #require(vector.normalized())
        #expect(abs(unit.norm - 1) < 1e-12)
        #expect(unit.z < 0 && unit.x == 0 && unit.y == 0)
    }

    @Test("normalizing a zero vector returns nil, never NaN")
    func normalizeZero() {
        #expect(Vector3.zero.normalized() == nil)
        #expect(Vector3(x: 1e-13, y: 0, z: 0).normalized() == nil)
    }

    @Test("arithmetic composes: (a + b) - b == a")
    func arithmetic() {
        let a = Vector3(x: 1.5, y: -2.25, z: 0.125)
        let b = Vector3(x: -0.5, y: 4, z: 8)
        #expect((a + b) - b == a)
        #expect(-a == a.scaled(by: -1))
    }
}
