import Foundation
import SOCore
import SOTelemetry

/// Thresholds for live course tracking. Configurable — corridor width and
/// grace periods are product/anti-cheat tuning, not code constants.
public struct CourseProgressConfig: Codable, Sendable, Equatable {
    /// Lateral distance from the course line beyond which a fix is
    /// off-course, meters (GPS noise + lane widths live inside this).
    public var corridorWidthMeters: Double
    /// Continuous off-course time that turns an excursion into a route
    /// deviation, seconds (spec §78: deviated runs don't rank).
    public var deviationGraceSeconds: Double
    /// Matching window behind the cursor, meters.
    public var backtrackMeters: Double
    /// Matching window ahead of the cursor, meters.
    public var lookaheadMeters: Double

    public init(
        corridorWidthMeters: Double,
        deviationGraceSeconds: Double,
        backtrackMeters: Double,
        lookaheadMeters: Double
    ) {
        self.corridorWidthMeters = corridorWidthMeters
        self.deviationGraceSeconds = deviationGraceSeconds
        self.backtrackMeters = backtrackMeters
        self.lookaheadMeters = lookaheadMeters
    }

    public static let `default` = CourseProgressConfig(
        corridorWidthMeters: 40,
        deviationGraceSeconds: 5,
        backtrackMeters: 100,
        lookaheadMeters: 400
    )
}

/// A checkpoint gate passed in order.
public struct CheckpointHit: Codable, Sendable, Equatable {
    public var sequence: Int
    public var timestamp: Double
    /// Course progress when the gate was hit, meters — ghost segment timing
    /// hangs off this.
    public var progressMeters: Double
}

/// A continuous window spent outside the course corridor.
public struct OffCourseExcursion: Codable, Sendable, Equatable {
    public var startTime: Double
    public var endTime: Double
    public var maxLateralOffsetMeters: Double

    public var duration: Double { endTime - startTime }
}

/// Live course tracking: monotone progress along the course, in-order
/// checkpoint gating, off-course/deviation detection, finish detection
/// (spec §§24, 71). Feed trajectory points in timestamp order.
///
/// Progress is the maximum matched course distance while inside the
/// corridor — it never runs backward and never advances while off-course,
/// so cutting a corner cannot buy progress (anti-cheat input, spec §45).
public struct CourseProgressTracker: Sendable {
    public let config: CourseProgressConfig
    private let matcher: CourseMatcher
    private let checkpoints: [Checkpoint]

    /// Monotone course progress, meters.
    public private(set) var progressMeters = 0.0
    /// Gates passed so far, in order.
    public private(set) var checkpointHits: [CheckpointHit] = []
    /// Closed off-course windows (an open one is added on the fix that ends it).
    public private(set) var offCourseExcursions: [OffCourseExcursion] = []
    public private(set) var isOffCourse = false

    private var openExcursionStart: Double?
    private var openExcursionMaxOffset = 0.0
    private var lastIngestTimestamp: Double?

    /// Fails on degenerate course geometry.
    public init?(
        polyline: [GeoCoordinate],
        checkpoints: [Checkpoint],
        config: CourseProgressConfig = .default
    ) {
        guard let matcher = CourseMatcher(polyline: polyline) else { return nil }
        self.matcher = matcher
        self.checkpoints = checkpoints.sorted { $0.sequence < $1.sequence }
        self.config = config
    }

    public var totalDistanceMeters: Double { matcher.totalDistanceMeters }

    /// Course progress normalized to 0...1 — the ghost-trajectory axis.
    public var progressFraction: Double {
        matcher.totalDistanceMeters > 0 ? min(1, progressMeters / matcher.totalDistanceMeters) : 0
    }

    /// The next gate the driver must pass, or nil when all are hit.
    public var nextCheckpoint: Checkpoint? {
        checkpointHits.count < checkpoints.count ? checkpoints[checkpointHits.count] : nil
    }

    /// All gates (including the finish) passed in order.
    public var hasFinished: Bool {
        !checkpoints.isEmpty && checkpointHits.count == checkpoints.count
    }

    /// True once any excursion exceeded the deviation grace — the run left
    /// the course (spec §78: won't appear on the leaderboard). An excursion
    /// still open at the last ingested fix counts: a run that leaves the
    /// course and never properly returns must not read as clean.
    public var deviationDetected: Bool {
        if offCourseExcursions.contains(where: { $0.duration > config.deviationGraceSeconds }) {
            return true
        }
        if let start = openExcursionStart, let last = lastIngestTimestamp {
            return last - start > config.deviationGraceSeconds
        }
        return false
    }

    public mutating func ingest(_ point: TrajectoryPoint) {
        lastIngestTimestamp = point.timestamp

        // Two different questions, two different matches:
        // "am I on the course at all?" — judged against the WHOLE course
        // (a deviated path can wander near a later bend inside the progress
        // window and must still count as off-course when it isn't near any
        // of it); "where along the course am I?" — judged inside the cursor
        // window so self-crossing courses can't teleport progress.
        let global = matcher.nearestMatch(to: point.coordinate)
        let windowed = matcher.match(
            point.coordinate,
            near: progressMeters,
            backtrackMeters: config.backtrackMeters,
            lookaheadMeters: config.lookaheadMeters
        )

        if global.lateralOffsetMeters <= config.corridorWidthMeters {
            if let start = openExcursionStart {
                offCourseExcursions.append(OffCourseExcursion(
                    startTime: start,
                    endTime: point.timestamp,
                    maxLateralOffsetMeters: openExcursionMaxOffset
                ))
                openExcursionStart = nil
                openExcursionMaxOffset = 0
            }
            isOffCourse = false
            // Progress advances only when the windowed match agrees the fix
            // is on the local stretch — corner-cutting and rejoin-far-ahead
            // buy nothing.
            if windowed.lateralOffsetMeters <= config.corridorWidthMeters {
                progressMeters = max(progressMeters, windowed.distanceAlongCourseMeters)
            }
        } else {
            if openExcursionStart == nil {
                openExcursionStart = point.timestamp
            }
            openExcursionMaxOffset = max(openExcursionMaxOffset, global.lateralOffsetMeters)
            isOffCourse = true
        }

        // Gate the next expected checkpoint only — later gates entered out
        // of order do not count (route skipping shows up as missing hits).
        if let next = nextCheckpoint, next.contains(point.coordinate) {
            checkpointHits.append(CheckpointHit(
                sequence: next.sequence,
                timestamp: point.timestamp,
                progressMeters: progressMeters
            ))
        }
    }

    /// Convenience: run a whole processed trajectory through the tracker.
    public mutating func ingest(_ trajectory: ProcessedTrajectory) {
        for point in trajectory.points {
            ingest(point)
        }
    }
}
