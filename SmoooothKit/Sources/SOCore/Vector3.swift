import Foundation

/// Minimal 3D vector for sensor-frame math (device → vehicle transforms,
/// gravity estimation). Owned here so every engine shares one definition.
public struct Vector3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    public var norm: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    /// Unit vector in the same direction; `nil` for (near-)zero vectors,
    /// where direction is undefined.
    public func normalized(epsilon: Double = 1e-12) -> Vector3? {
        let n = norm
        guard n > epsilon else { return nil }
        return Vector3(x: x / n, y: y / n, z: z / n)
    }

    public func scaled(by factor: Double) -> Vector3 {
        Vector3(x: x * factor, y: y * factor, z: z * factor)
    }

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static prefix func - (vector: Vector3) -> Vector3 {
        Vector3(x: -vector.x, y: -vector.y, z: -vector.z)
    }
}
