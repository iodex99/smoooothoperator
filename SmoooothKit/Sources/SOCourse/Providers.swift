import SOCore

/// External-service seams (spec §91). The engines never talk to a map
/// vendor directly — providers are injected, fakes ship with the Kit, and
/// real implementations (Apple/OSRM/Overpass…) slot into the iOS layer or
/// server later without touching engine code. v1 course matching needs NO
/// provider: the course polyline is the reference geometry.

/// Computes a drivable route through ordered waypoints.
public protocol RoutingProvider: Sendable {
    func route(through waypoints: [GeoCoordinate]) async throws -> [GeoCoordinate]
}

/// Snaps noisy fixes onto road geometry.
public protocol MapMatchingProvider: Sendable {
    func snapToRoads(_ points: [GeoCoordinate]) async throws -> [GeoCoordinate]
}

/// A stretch of course with a known legal speed limit. `limitMps` nil means
/// no reliable data — compliance scoring must NOT infer violations there
/// (spec §41).
public struct SpeedLimitSegment: Codable, Sendable, Equatable {
    public var startDistanceMeters: Double
    public var endDistanceMeters: Double
    public var limitMps: Double?

    public init(startDistanceMeters: Double, endDistanceMeters: Double, limitMps: Double?) {
        self.startDistanceMeters = startDistanceMeters
        self.endDistanceMeters = endDistanceMeters
        self.limitMps = limitMps
    }
}

/// Provides legal speed limits along a course polyline.
public protocol SpeedLimitProvider: Sendable {
    func speedLimits(along polyline: [GeoCoordinate]) async throws -> [SpeedLimitSegment]
}

// MARK: - Fakes (deterministic, for tests and development)

/// Returns the waypoints as-is: a straight-line "route".
public struct StraightLineRoutingProvider: RoutingProvider {
    public init() {}

    public func route(through waypoints: [GeoCoordinate]) async throws -> [GeoCoordinate] {
        waypoints
    }
}

/// Returns points unchanged.
public struct IdentityMapMatchingProvider: MapMatchingProvider {
    public init() {}

    public func snapToRoads(_ points: [GeoCoordinate]) async throws -> [GeoCoordinate] {
        points
    }
}

/// One uniform limit over the whole course (nil = no data anywhere).
public struct FixedSpeedLimitProvider: SpeedLimitProvider {
    public let limitMps: Double?

    public init(limitMps: Double?) {
        self.limitMps = limitMps
    }

    public func speedLimits(along polyline: [GeoCoordinate]) async throws -> [SpeedLimitSegment] {
        guard polyline.count >= 2 else { return [] }
        var total = 0.0
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            total += a.distance(to: b)
        }
        return [SpeedLimitSegment(startDistanceMeters: 0, endDistanceMeters: total, limitMps: limitMps)]
    }
}
