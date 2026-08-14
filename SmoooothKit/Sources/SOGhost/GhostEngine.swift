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

    /// The inverse: where the ghost IS at a given elapsed time (0...1 course
    /// fraction). This is what lets the drive map draw the rival's pin
    /// alongside your own, rather than only reporting a gap in seconds.
    ///
    /// Clamps at both ends: before the ghost started it sits at the line,
    /// and once it has finished it stays at the finish rather than running
    /// off the end of the course.
    public func progress(atElapsed elapsed: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if elapsed <= first.elapsedSeconds { return first.progress }
        if elapsed >= last.elapsedSeconds { return last.progress }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].elapsedSeconds <= elapsed { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = b.elapsedSeconds - a.elapsedSeconds
        guard span > 0 else { return a.progress }
        let t = (elapsed - a.elapsedSeconds) / span
        return a.progress + t * (b.progress - a.progress)
    }
}

/// Ghost generation parameters.
public struct GhostConfig: Codable, Sendable, Equatable {
    /// Target progress spacing between stored points (fraction of course).
    /// 0.005 → ≤ ~200 points per ghost regardless of course length.
    public var progressResolution: Double
    /// Ghosts only come from finished runs; generation fails otherwise.
    public var requireFinished: Bool
    /// The ghost clock starts once the car has moved this far from where it
    /// crossed the start gate. Drivers stage INSIDE the start gate (spec §16
    /// calibration) and parked time must never count — but the anchor is
    /// DISPLACEMENT, not a speed threshold.
    ///
    /// This is the fix for a real defect. The rule used to be "first sample
    /// faster than 1.5 m/s", and the live clock applied it to the device's
    /// reported speed while the ghost clock applied it to the smoothed,
    /// derived speed of a processed trajectory. Any threshold on a filtered
    /// derivative lags the raw signal, so the two clocks started at
    /// different instants and a driver racing their own best run was shown
    /// permanently ~2.6 s ahead of themselves.
    ///
    /// Displacement has no such lag: smoothing moves a point slightly, it
    /// does not systematically delay when the car has covered five metres.
    public var startMovingMeters: Double

    public init(progressResolution: Double, requireFinished: Bool, startMovingMeters: Double) {
        self.progressResolution = progressResolution
        self.requireFinished = requireFinished
        self.startMovingMeters = startMovingMeters
    }

    public static let `default` = GhostConfig(
        progressResolution: 0.005,
        requireFinished: true,
        startMovingMeters: 5
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

        // Replay the trajectory, sampling (elapsed, progress, position) as
        // it grows. Position rather than speed: the clock anchor is a
        // displacement, which does not lag the way a filtered speed does.
        var raw: [(timestamp: Double, progress: Double, coordinate: GeoCoordinate)] = []
        for point in trajectory.points {
            tracker.ingest(point)
            raw.append((point.timestamp, tracker.progressFraction, point.coordinate))
        }

        if config.requireFinished && !tracker.hasFinished {
            throw GhostGenerationError.runDidNotFinish
        }
        guard let startHit = tracker.checkpointHits.first(where: { $0.sequence == 0 }) else {
            throw GhostGenerationError.noStartCrossing
        }

        // Start crossing: the first fix at/after the start-gate hit that is
        // `startMovingMeters` away from where the gate was crossed. Staging
        // inside the gate never counts on the clock, and the SAME rule runs
        // on the live side so the two clocks cannot disagree (ADR-0002).
        let startTime = GhostEngine.startTime(
            samples: raw.map { ($0.timestamp, $0.coordinate) },
            gateHitTimestamp: startHit.timestamp,
            movedMeters: config.startMovingMeters
        )

        let finishTime = tracker.checkpointHits.last.map(\.timestamp) ?? raw.last?.timestamp ?? startTime

        // Downsample to the progress resolution, keeping monotonicity in
        // both axes. Points before the start crossing are staging noise.
        //
        // The first point is the progress the car had AT the start instant,
        // not a forced zero. Pinning (0, 0) claimed the car was at the very
        // beginning of the course when the clock started — but the clock
        // starts once it has moved `startMovingMeters`, so it is already a
        // little way along. Everything between 0 and that progress was then
        // interpolated from a fictional origin, which showed a driver racing
        // their own run as ~1.8 s ahead of themselves for the first half.
        let startProgress = min(
            1,
            raw.last(where: { $0.timestamp <= startTime })?.progress ?? 0
        )
        var points: [GhostPoint] = [GhostPoint(progress: startProgress, elapsedSeconds: 0)]
        var lastStoredProgress = startProgress
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
        // The final point is the progress the car ACTUALLY had when it
        // crossed the finish gate — not a forced 1.0.
        //
        // A run ends on entering the finish gate, which is a circle tens of
        // metres wide, so the car is typically at ~0.986 rather than 1.0.
        // Pinning the last point to 1.0 stretched the ghost's final segment
        // across progress the driver never covers, and a live run whose
        // progress plateaus just short of 1.0 was compared against a ghost
        // that claimed to still be moving. That showed a driver racing their
        // own run as ~1.8 s off over the final tenth of the course — the
        // mirror image of the same mistake at the start.
        let finishProgress = min(
            1,
            max(
                points.last?.progress ?? 0,
                raw.last(where: { $0.timestamp <= finishTime })?.progress ?? 1
            )
        )
        if (points.last?.progress ?? 0) < finishProgress {
            points.append(GhostPoint(progress: finishProgress, elapsedSeconds: totalSeconds))
        }

        return GhostTrajectory(points: points, totalSeconds: totalSeconds)
    }

    /// When the clock starts, given samples and the instant the start gate
    /// was crossed.
    ///
    /// Shared deliberately: the live session and ghost generation call this
    /// same function so the two clocks anchor on one rule rather than two
    /// that happen to look alike. They previously did not, and the result
    /// was a driver beating themselves by 2.6 seconds.
    public static func startTime(
        samples: [(timestamp: Double, coordinate: GeoCoordinate)],
        gateHitTimestamp: Double,
        movedMeters: Double
    ) -> Double {
        guard let origin = samples.first(where: { $0.timestamp >= gateHitTimestamp })?.coordinate
        else { return gateHitTimestamp }
        for sample in samples where sample.timestamp >= gateHitTimestamp {
            if origin.distance(to: sample.coordinate) >= movedMeters {
                return sample.timestamp
            }
        }
        // Never moved far enough — the gate hit is the only honest answer.
        return gateHitTimestamp
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
