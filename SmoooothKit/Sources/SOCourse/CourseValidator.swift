import Foundation
import SOCore

/// Limits for validating a course before it can be published (spec §25).
/// All limits configurable — rejection thresholds are product decisions,
/// not code constants.
public struct CourseValidationConfig: Codable, Sendable, Equatable {
    public var minDistanceMeters: Double
    public var maxDistanceMeters: Double
    /// Route points further apart than this can hide geometry (rivers,
    /// buildings) between them — the route is too coarse to validate.
    public var maxPointSpacingMeters: Double
    /// Start + finish at minimum.
    public var minCheckpoints: Int
    /// A checkpoint's center must sit within this distance of the route line.
    public var maxCheckpointOffRouteMeters: Double
    /// Consecutive checkpoints closer than this (along the course) make
    /// gates meaningless.
    public var minCheckpointSpacingMeters: Double

    public init(
        minDistanceMeters: Double,
        maxDistanceMeters: Double,
        maxPointSpacingMeters: Double,
        minCheckpoints: Int,
        maxCheckpointOffRouteMeters: Double,
        minCheckpointSpacingMeters: Double
    ) {
        self.minDistanceMeters = minDistanceMeters
        self.maxDistanceMeters = maxDistanceMeters
        self.maxPointSpacingMeters = maxPointSpacingMeters
        self.minCheckpoints = minCheckpoints
        self.maxCheckpointOffRouteMeters = maxCheckpointOffRouteMeters
        self.minCheckpointSpacingMeters = minCheckpointSpacingMeters
    }

    public static let `default` = CourseValidationConfig(
        minDistanceMeters: 1_000,
        maxDistanceMeters: 80_000,
        maxPointSpacingMeters: 500,
        minCheckpoints: 2,
        maxCheckpointOffRouteMeters: 30,
        minCheckpointSpacingMeters: 200
    )
}

/// One reason a course cannot be published. A validation run returns ALL
/// issues found, not just the first — creators fix everything in one pass.
public enum CourseValidationIssue: Codable, Sendable, Equatable {
    case tooShort(distanceMeters: Double)
    case tooLong(distanceMeters: Double)
    case insufficientRoutePoints(count: Int)
    case invalidCoordinate(index: Int)
    case excessivePointSpacing(index: Int, meters: Double)
    case insufficientCheckpoints(count: Int)
    case duplicateCheckpointSequence(sequence: Int)
    case nonContiguousCheckpointSequence
    case checkpointOffRoute(sequence: Int, meters: Double)
    case checkpointsOutOfOrder(sequence: Int)
    case checkpointsTooClose(sequence: Int, meters: Double)
    case startNotAtRouteStart(meters: Double)
    case finishNotAtRouteEnd(meters: Double)
}

/// Validates course geometry + checkpoints before publishing (spec §25).
/// The same rules are ported to TypeScript in the validate-course edge
/// function (L8) and cross-checked with shared fixtures — the server rejects
/// everything the client rejects.
public struct CourseValidator: Sendable {
    public let config: CourseValidationConfig

    public init(config: CourseValidationConfig = .default) {
        self.config = config
    }

    public func validate(polyline: [GeoCoordinate], checkpoints: [Checkpoint]) -> [CourseValidationIssue] {
        var issues: [CourseValidationIssue] = []

        // ── Geometry ──────────────────────────────────────────────────────
        if polyline.count < 2 {
            issues.append(.insufficientRoutePoints(count: polyline.count))
        }
        for (index, point) in polyline.enumerated() {
            let latValid = point.latitude.isFinite && abs(point.latitude) <= 90
            let lonValid = point.longitude.isFinite && abs(point.longitude) <= 180
            if !latValid || !lonValid {
                issues.append(.invalidCoordinate(index: index))
            }
        }
        guard issues.isEmpty, let matcher = CourseMatcher(polyline: polyline) else {
            return issues.isEmpty ? [.insufficientRoutePoints(count: polyline.count)] : issues
        }

        let distance = matcher.totalDistanceMeters
        if distance < config.minDistanceMeters {
            issues.append(.tooShort(distanceMeters: distance))
        }
        if distance > config.maxDistanceMeters {
            issues.append(.tooLong(distanceMeters: distance))
        }
        for (index, (a, b)) in zip(polyline, polyline.dropFirst()).enumerated() {
            let spacing = a.distance(to: b)
            if spacing > config.maxPointSpacingMeters {
                issues.append(.excessivePointSpacing(index: index, meters: spacing))
            }
        }

        // ── Checkpoints ───────────────────────────────────────────────────
        if checkpoints.count < config.minCheckpoints {
            issues.append(.insufficientCheckpoints(count: checkpoints.count))
        }
        let ordered = checkpoints.sorted { $0.sequence < $1.sequence }
        var seenSequences = Set<Int>()
        for checkpoint in ordered where !seenSequences.insert(checkpoint.sequence).inserted {
            issues.append(.duplicateCheckpointSequence(sequence: checkpoint.sequence))
        }
        if !ordered.isEmpty, ordered.map(\.sequence) != Array(0..<ordered.count) {
            issues.append(.nonContiguousCheckpointSequence)
        }

        var previousAlongCourse = -Double.infinity
        var previousSequence = -1
        for checkpoint in ordered {
            let match = matcher.nearestMatch(to: checkpoint.center)
            if match.lateralOffsetMeters > config.maxCheckpointOffRouteMeters {
                issues.append(.checkpointOffRoute(
                    sequence: checkpoint.sequence, meters: match.lateralOffsetMeters
                ))
                continue  // its course position is meaningless
            }
            if match.distanceAlongCourseMeters < previousAlongCourse {
                issues.append(.checkpointsOutOfOrder(sequence: checkpoint.sequence))
            } else if previousSequence >= 0 {
                let spacing = match.distanceAlongCourseMeters - previousAlongCourse
                if spacing < config.minCheckpointSpacingMeters {
                    issues.append(.checkpointsTooClose(sequence: checkpoint.sequence, meters: spacing))
                }
            }
            previousAlongCourse = match.distanceAlongCourseMeters
            previousSequence = checkpoint.sequence

            if checkpoint.sequence == 0 {
                let fromStart = match.distanceAlongCourseMeters
                if fromStart > checkpoint.radiusMeters * 2 {
                    issues.append(.startNotAtRouteStart(meters: fromStart))
                }
            }
            if checkpoint.sequence == ordered.count - 1 {
                let fromEnd = matcher.totalDistanceMeters - match.distanceAlongCourseMeters
                if fromEnd > checkpoint.radiusMeters * 2 {
                    issues.append(.finishNotAtRouteEnd(meters: fromEnd))
                }
            }
        }

        return issues
    }
}
