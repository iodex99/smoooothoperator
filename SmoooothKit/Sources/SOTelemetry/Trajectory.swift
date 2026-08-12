import SOCore

/// One cleaned, filtered point of a reconstructed trajectory.
/// Produced by `TrajectoryProcessor` from raw GPS; raw samples are never
/// mutated (spec §22 — raw and processed telemetry stay separate).
public struct TrajectoryPoint: Codable, Sendable, Equatable {
    /// Seconds since Unix epoch.
    public var timestamp: Double
    public var coordinate: GeoCoordinate
    /// Filtered ground speed, m/s (never negative).
    public var speedMps: Double
    /// Direction of travel in degrees from true north; nil while unknown
    /// (e.g. stationary start).
    public var headingDegrees: Double?
    /// Cumulative distance from the first point, meters (non-decreasing).
    public var distanceAlongPathMeters: Double
    /// Accuracy of the underlying fix, meters.
    public var horizontalAccuracy: Double

    public init(
        timestamp: Double,
        coordinate: GeoCoordinate,
        speedMps: Double,
        headingDegrees: Double?,
        distanceAlongPathMeters: Double,
        horizontalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.speedMps = speedMps
        self.headingDegrees = headingDegrees
        self.distanceAlongPathMeters = distanceAlongPathMeters
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// A window of missing/unusable data discovered during processing.
public struct TelemetryGap: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case noSamples          // nothing arrived
        case rejectedSamples    // samples arrived but were unusable
    }

    public var startTime: Double
    public var endTime: Double
    public var reason: Reason

    public init(startTime: Double, endTime: Double, reason: Reason) {
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
    }

    public var duration: Double { endTime - startTime }
}

/// The reconstructed path of a run.
public struct ProcessedTrajectory: Codable, Sendable, Equatable {
    public var points: [TrajectoryPoint]
    public var gaps: [TelemetryGap]
    /// Count of raw samples rejected by filtering (accuracy gate, outliers,
    /// non-monotonic timestamps). Feeds LocationConfidence and integrity.
    public var rejectedSampleCount: Int

    public init(points: [TrajectoryPoint], gaps: [TelemetryGap], rejectedSampleCount: Int) {
        self.points = points
        self.gaps = gaps
        self.rejectedSampleCount = rejectedSampleCount
    }

    public var totalDistanceMeters: Double {
        points.last?.distanceAlongPathMeters ?? 0
    }

    public var duration: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.timestamp - first.timestamp
    }
}
