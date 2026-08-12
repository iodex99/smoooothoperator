import SOCore
import SOModels

/// An ordered gate on a course: start, intermediate checkpoints, finish.
/// Checkpoints drive route validation, progress, ghost alignment, segment
/// scoring, and anti-cheat (spec §24).
public struct Checkpoint: Codable, Sendable, Equatable {
    /// Position in the course's checkpoint ordering (0 = start).
    public var sequence: Int
    public var center: GeoCoordinate
    public var radiusMeters: Double

    public init(sequence: Int, center: GeoCoordinate, radiusMeters: Double) {
        self.sequence = sequence
        self.center = center
        self.radiusMeters = radiusMeters
    }

    /// Whether a GPS fix falls inside this checkpoint's gate radius.
    public func contains(_ coordinate: GeoCoordinate) -> Bool {
        center.distance(to: coordinate) <= radiusMeters
    }
}
