import SOCore

/// Filtering and reconstruction thresholds for `TrajectoryProcessor`.
/// Every threshold lives here — nothing is hard-coded in the pipeline
/// (spec §21) — so tuning is a data change, not a code change.
public struct TrajectoryConfig: Codable, Sendable, Equatable {
    /// Fixes whose horizontal accuracy is worse than this (meters) are
    /// rejected. Negative accuracy always rejects (invalid fix).
    public var maxHorizontalAccuracyMeters: Double
    /// Straight-line speed (m/s) implied between the previous kept fix and a
    /// candidate above which the candidate is rejected as a GPS teleport.
    public var maxPlausibleSpeedMps: Double
    /// Time between consecutive kept fixes (seconds) above which a
    /// `TelemetryGap` is recorded.
    public var gapThresholdSeconds: Double
    /// At or below this speed (m/s) a derived heading is bearing noise, so
    /// `headingDegrees` stays nil unless the fix carries a GPS course.
    public var minMovingSpeedMps: Double

    public init(
        maxHorizontalAccuracyMeters: Double,
        maxPlausibleSpeedMps: Double,
        gapThresholdSeconds: Double,
        minMovingSpeedMps: Double
    ) {
        self.maxHorizontalAccuracyMeters = maxHorizontalAccuracyMeters
        self.maxPlausibleSpeedMps = maxPlausibleSpeedMps
        self.gapThresholdSeconds = gapThresholdSeconds
        self.minMovingSpeedMps = minMovingSpeedMps
    }

    /// Spec §21 initial thresholds.
    public static let `default` = TrajectoryConfig(
        maxHorizontalAccuracyMeters: 30,
        maxPlausibleSpeedMps: 90,
        gapThresholdSeconds: 3,
        minMovingSpeedMps: 1
    )
}

/// Rebuilds a clean `ProcessedTrajectory` from raw GPS samples (spec §21).
///
/// Raw samples are inputs only and are never mutated (spec §22). Samples are
/// consumed in arrival order and pass three gates — accuracy, monotonic
/// timestamps (earliest arrival wins), and the implied-speed teleport gate —
/// with every failure counted in `rejectedSampleCount`. Survivors become
/// `TrajectoryPoint`s with derived speed, heading, and cumulative haversine
/// distance; windows between kept points longer than `gapThresholdSeconds`
/// are reported as `TelemetryGap`s.
public struct TrajectoryProcessor: Sendable {
    public let config: TrajectoryConfig

    public init(config: TrajectoryConfig = .default) {
        self.config = config
    }

    /// Processes raw samples into a trajectory. Output timestamps are
    /// strictly increasing and `distanceAlongPathMeters` is non-decreasing,
    /// regardless of how disordered the input is.
    public func process(_ samples: [GPSSample]) -> ProcessedTrajectory {
        var points: [TrajectoryPoint] = []
        var gaps: [TelemetryGap] = []
        var rejectedCount = 0
        // Rejections since the last kept point, used to attribute gap reason.
        var rejectedSinceLastKept = 0

        for sample in samples {
            // Gate 0 — finiteness. NaN passes every comparison below (all NaN
            // comparisons are false), so an unguarded NaN fix is KEPT and then
            // poisons the teleport gate for every later sample: a whole valid
            // drive reports 0 m travelled and 0 gates hit.
            guard sample.timestamp.isFinite,
                sample.coordinate.latitude.isFinite,
                sample.coordinate.longitude.isFinite,
                sample.horizontalAccuracy.isFinite
            else {
                rejectedCount += 1
                rejectedSinceLastKept += 1
                continue
            }

            // Gate 1 — accuracy: negative means invalid fix, large means noise.
            guard sample.horizontalAccuracy >= 0,
                sample.horizontalAccuracy <= config.maxHorizontalAccuracyMeters
            else {
                rejectedCount += 1
                rejectedSinceLastKept += 1
                continue
            }

            guard let previous = points.last else {
                // First kept point: nothing to derive against.
                let speed: Double =
                    if let reported = sample.speed, reported >= 0 { max(0, reported) } else { 0 }
                points.append(
                    TrajectoryPoint(
                        timestamp: sample.timestamp,
                        coordinate: sample.coordinate,
                        speedMps: speed,
                        headingDegrees: sample.course,
                        distanceAlongPathMeters: 0,
                        horizontalAccuracy: sample.horizontalAccuracy
                    ))
                rejectedSinceLastKept = 0
                continue
            }

            // Gate 2 — monotonic time: on regression or duplicate, the
            // earliest arrival (already kept) wins.
            let dt = sample.timestamp - previous.timestamp
            guard dt > 0 else {
                rejectedCount += 1
                rejectedSinceLastKept += 1
                continue
            }

            // Gate 3 — teleport: implied straight-line speed from the
            // previous kept point must stay physically plausible.
            let stepMeters = previous.coordinate.distance(to: sample.coordinate)
            let impliedSpeed = stepMeters / dt
            guard impliedSpeed <= config.maxPlausibleSpeedMps else {
                rejectedCount += 1
                rejectedSinceLastKept += 1
                continue
            }

            let speed: Double =
                if let reported = sample.speed, reported >= 0 {
                    max(0, reported)
                } else {
                    max(0, impliedSpeed)
                }

            let heading: Double?
            if let course = sample.course {
                heading = course
            } else if speed > config.minMovingSpeedMps {
                heading = previous.coordinate.bearing(to: sample.coordinate)
            } else {
                heading = nil
            }

            if dt > config.gapThresholdSeconds {
                gaps.append(
                    TelemetryGap(
                        startTime: previous.timestamp,
                        endTime: sample.timestamp,
                        reason: rejectedSinceLastKept > 0 ? .rejectedSamples : .noSamples
                    ))
            }

            points.append(
                TrajectoryPoint(
                    timestamp: sample.timestamp,
                    coordinate: sample.coordinate,
                    speedMps: speed,
                    headingDegrees: heading,
                    distanceAlongPathMeters: previous.distanceAlongPathMeters + stepMeters,
                    horizontalAccuracy: sample.horizontalAccuracy
                ))
            rejectedSinceLastKept = 0
        }

        return ProcessedTrajectory(
            points: points, gaps: gaps, rejectedSampleCount: rejectedCount
        )
    }
}
