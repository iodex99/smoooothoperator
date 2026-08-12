import Foundation
import SOCore
import SOCourse
import SOTelemetry

/// A compact, privacy-safe replay of a verified run (spec §§32-36):
/// normalized course progress against elapsed time — never raw GPS, never
/// coordinates. Small enough to store as a JSONB row and stream to rivals.
public struct GhostTrajectory: Codable, Sendable, Equatable {
    /// Monotone in both progress and time; first point is the start-line
    /// crossing (progress 0, elapsed 0), last is the finish.
    public var points: [GhostPoint]
    /// Total elapsed seconds start→finish.
    public var totalSeconds: Double

    public init(points: [GhostPoint], totalSeconds: Double) {
        self.points = points
        self.totalSeconds = totalSeconds
    }

    /// Elapsed seconds at a given progress fraction (linear interpolation;
    /// clamped at the ends).
    public func elapsedSeconds(atProgress progress: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if progress <= first.progress { return first.elapsedSeconds }
        if progress >= last.progress { return last.elapsedSeconds }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].progress <= progress { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = b.progress - a.progress
        guard span > 0 else { return a.elapsedSeconds }
        let t = (progress - a.progress) / span
        return a.elapsedSeconds + t * (b.elapsedSeconds - a.elapsedSeconds)
    }
}

/// Ghost generation parameters.
public struct GhostConfig: Codable, Sendable, Equatable {
    /// Target progress spacing between stored points (fraction of course).
    /// 0.005 → ≤ ~200 points per ghost regardless of course length.
    public var progressResolution: Double
    /// Ghosts only come from finished runs; generation fails otherwise.
    public var requireFinished: Bool
    /// The ghost clock starts at the first fix after the start-gate hit
    /// moving faster than this (m/s) — drivers stage INSIDE the start gate
    /// (spec §16 calibration), and parked time must never count.
    public var startMovingSpeedMps: Double

    public init(progressResolution: Double, requireFinished: Bool, startMovingSpeedMps: Double) {
        self.progressResolution = progressResolution
        self.requireFinished = requireFinished
        self.startMovingSpeedMps = startMovingSpeedMps
    }

    public static let `default` = GhostConfig(
        progressResolution: 0.005,
        requireFinished: true,
        startMovingSpeedMps: 1.5
    )
}

public enum GhostGenerationError: Error, Equatable {
    case degenerateCourse
    case runDidNotFinish
    case noStartCrossing
}

/// Builds ghosts from processed trajectories and compares live runs against
/// them (spec §§32-34). The elapsed clock starts at the start-line gate hit —
/// staging time before the line never counts.
public enum GhostEngine {
    /// Generates a normalized ghost from a run's trajectory on a course.
    public static func generate(
        trajectory: ProcessedTrajectory,
        polyline: [GeoCoordinate],
        checkpoints: [Checkpoint],
        config: GhostConfig = .default
    ) throws -> GhostTrajectory {
        guard var tracker = CourseProgressTracker(polyline: polyline, checkpoints: checkpoints) else {
            throw GhostGenerationError.degenerateCourse
        }

        // Replay the trajectory, sampling (elapsed, progress, speed) as it grows.
        var raw: [(timestamp: Double, progress: Double, speedMps: Double)] = []
        for point in trajectory.points {
            tracker.ingest(point)
            raw.append((point.timestamp, tracker.progressFraction, point.speedMps))
        }

        if config.requireFinished && !tracker.hasFinished {
            throw GhostGenerationError.runDidNotFinish
        }
        guard let startHit = tracker.checkpointHits.first(where: { $0.sequence == 0 }) else {
            throw GhostGenerationError.noStartCrossing
        }

        // Start crossing: the first moving fix at/after the start-gate hit —
        // staging inside the gate never counts on the clock.
        let startTime = raw.first(where: {
            $0.timestamp >= startHit.timestamp && $0.speedMps > config.startMovingSpeedMps
        })?.timestamp ?? startHit.timestamp

        let finishTime = tracker.checkpointHits.last.map(\.timestamp) ?? raw.last?.timestamp ?? startTime

        // Downsample to the progress resolution, keeping monotonicity in
        // both axes. Points before the start crossing are staging noise.
        var points: [GhostPoint] = [GhostPoint(progress: 0, elapsedSeconds: 0)]
        var lastStoredProgress = 0.0
        for sample in raw where sample.timestamp > startTime && sample.timestamp <= finishTime {
            let progress = min(1, sample.progress)
            guard progress >= lastStoredProgress + config.progressResolution else { continue }
            points.append(GhostPoint(
                progress: progress,
                elapsedSeconds: sample.timestamp - startTime
            ))
            lastStoredProgress = progress
        }
        let totalSeconds = finishTime - startTime
        if points.last?.progress ?? 0 < 1 {
            points.append(GhostPoint(progress: 1, elapsedSeconds: totalSeconds))
        }

        return GhostTrajectory(points: points, totalSeconds: totalSeconds)
    }

    /// Live gap vs a ghost: positive = you are BEHIND the ghost by that many
    /// seconds at your current progress; negative = ahead (spec §34).
    public static func gapSeconds(
        elapsedSeconds: Double,
        progress: Double,
        against ghost: GhostTrajectory
    ) -> Double {
        elapsedSeconds - ghost.elapsedSeconds(atProgress: progress)
    }
}
