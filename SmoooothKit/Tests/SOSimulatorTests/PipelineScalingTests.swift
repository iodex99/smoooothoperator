import Foundation
import Testing
import SOCore
import SOCourse
import SOModels
import SOScoring
import SOTelemetry
@testable import SOSimulator

/// Every other test in this package drives a course of about four minutes.
/// A driver will not. A canyon run, a commute, a coast road — a drive can
/// easily last an hour, and at 10 Hz GPS plus 50 Hz IMU an hour is 36,000
/// GPS samples and 180,000 IMU samples.
///
/// A single quadratic step anywhere in the pipeline is invisible at four
/// minutes and freezes the phone at sixty. Nothing here measured that, so
/// nothing here would have caught it.
///
/// These tests assert the SHAPE rather than a wall-clock time: grow the
/// input and the work must not grow like its square.
///
/// TWO THINGS LEARNED FROM GETTING THIS WRONG, both encoded below.
///
/// Measure where the work dominates. At a couple of thousand samples the
/// numbers are single-digit milliseconds and mostly fixed cost, so the ratio
/// between two small sizes says more about allocator warm-up than about the
/// algorithm — course building measured 8-10x for 3.7x the input in a debug
/// build while being 1.11 in a release one. The sizes below are the sizes a
/// real drive produces.
///
/// Take the best of several runs. This is a shared two-core box; a
/// scheduling hiccup inflates one sample and nothing detects it. The minimum
/// of N is the standard estimator for "how fast can this actually go" and it
/// is the only one of these that is stable.
@Suite("Pipeline scaling on a long drive")
struct PipelineScalingTests {
    /// A winding road of arbitrary length. Realism is not the point here;
    /// size is, and it has to be generated rather than fixed.
    static func longRoute(segments: Int, seed: UInt64) -> [GeoCoordinate] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        var route = [GeoCoordinate(latitude: 34.0259, longitude: -118.7798)]
        var heading = 40.0
        for segment in 0..<segments {
            heading += segment % 5 == 0
                ? Double.random(in: -35...35, using: &rng)
                : Double.random(in: -8...8, using: &rng)
            route.append(
                route[route.count - 1].destination(
                    bearingDegrees: heading,
                    distanceMeters: Double.random(in: 80...160, using: &rng)
                )
            )
        }
        return route
    }

    static let config: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    private static func gates(on route: [GeoCoordinate]) -> [Checkpoint] {
        [0.0, 0.25, 0.5, 0.75, 1.0].enumerated().map { index, fraction in
            let position = min(
                route.count - 1,
                max(0, Int((Double(route.count - 1) * fraction).rounded()))
            )
            return Checkpoint(sequence: index, center: route[position], radiusMeters: 40)
        }
    }

    /// Best of `attempts` — see the note above on why a minimum, not a mean.
    private static func fastest(
        attempts: Int = 3,
        _ body: () -> (seconds: Double, count: Int)
    ) -> (seconds: Double, count: Int) {
        var best = body()
        for _ in 1..<attempts {
            let next = body()
            if next.seconds < best.seconds { best = next }
        }
        return best
    }

    /// Seconds spent evaluating one simulated drive over `segments` of road.
    private static func evaluationSeconds(segments: Int) -> (seconds: Double, samples: Int) {
        let route = longRoute(segments: segments, seed: 77)
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 31).simulate(route: route)
        let gates = gates(on: route)

        let started = Date()
        let outcome = RunEvaluationPipeline.evaluate(
            gps: run.gps,
            imu: run.imu,
            route: route,
            gates: gates,
            benchmarkSeconds: max(run.groundTruth.expectedDurationSeconds * 0.97, 1),
            scoringConfig: config
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome != nil, "the pipeline must still produce a result on a long drive")
        return (elapsed, run.gps.count + run.imu.count)
    }

    @Test("evaluating a drive grows with its length, not with its length squared")
    func evaluationIsNotQuadratic() {
        _ = Self.evaluationSeconds(segments: 40)   // warm the code paths

        // Both sizes are real drive lengths — roughly 20 and 45 minutes.
        // Comparing two LARGE sizes is the point: at a couple of thousand
        // samples the measurement is mostly fixed cost.
        let small = Self.fastest { let r = Self.evaluationSeconds(segments: 200)
                                   return (r.seconds, r.samples) }
        let large = Self.fastest { let r = Self.evaluationSeconds(segments: 400)
                                   return (r.seconds, r.samples) }

        let inputRatio = Double(large.count) / Double(small.count)
        let timeRatio = large.seconds / max(small.seconds, 0.0001)

        // ~2× the input. Linear is ~2×, quadratic is ~4×. The bar sits
        // between them, closer to quadratic so ordinary noise cannot reach
        // it, and far enough below 4× that a quadratic step cannot hide.
        #expect(
            timeRatio < inputRatio * 1.6,
            """
            evaluation time grew \(String(format: "%.1f", timeRatio))× for \
            \(String(format: "%.1f", inputRatio))× the samples \
            (\(small.count) → \(large.count) samples, \
            \(String(format: "%.3f", small.seconds))s → \
            \(String(format: "%.3f", large.seconds))s). That is the signature \
            of a quadratic step in the pipeline.
            """
        )
    }

    @Test("an hour-long drive is evaluated in seconds, not minutes")
    func longDriveCompletesInReasonableTime() {
        // ~45 km of winding road — comfortably an hour of real driving, and
        // longer than any course a driver would race.
        let result = Self.evaluationSeconds(segments: 400)
        #expect(
            result.seconds < 30,
            """
            \(result.samples) samples took \
            \(String(format: "%.1f", result.seconds))s to evaluate. This runs \
            on the phone the moment a drive ends, with the driver watching.
            """
        )
    }

    /// The whole-pipeline test above is necessary and NOT sufficient, and
    /// finding that out is why this one exists.
    ///
    /// Course tracking was the quadratic stage. When the fix for it was
    /// temporarily reverted to check that the pipeline test would notice, the
    /// pipeline test PASSED: tracking is one stage among seven, the rest are
    /// linear, and quadrupling a third of the total does not move the total
    /// far enough to trip a threshold set loose enough to survive a noisy
    /// box. A guard that cannot fail on the bug it was written for is not a
    /// guard.
    ///
    /// So the stage is measured on its own, where the quadratic term is
    /// 100% of what is being timed and has nowhere to hide.
    @Test("course tracking grows with the drive, not with the drive squared")
    func courseTrackingIsNotQuadratic() {
        func trackingSeconds(segments: Int) -> (seconds: Double, count: Int) {
            let route = Self.longRoute(segments: segments, seed: 77)
            let run = TelemetrySimulator(profile: .fastSmooth, seed: 31).simulate(route: route)
            let trajectory = TrajectoryProcessor().process(run.gps)
            let gates = Self.gates(on: route)
            let started = Date()
            guard var tracker = CourseProgressTracker(polyline: route, checkpoints: gates) else {
                return (0, 0)
            }
            tracker.ingest(trajectory)
            return (Date().timeIntervalSince(started), trajectory.points.count)
        }

        _ = trackingSeconds(segments: 40)   // warm the code paths

        let small = Self.fastest { trackingSeconds(segments: 200) }
        let large = Self.fastest { trackingSeconds(segments: 400) }

        let inputRatio = Double(large.count) / Double(small.count)
        let timeRatio = large.seconds / max(small.seconds, 0.0001)

        // Tracking cost is (trajectory points x polyline segments), and this
        // route grows BOTH with `segments` — so an unwindowed match is
        // quadratic in this ratio: ~2x the input, ~4x the time. Linear is
        // ~2x. The bar sits between, and was checked against the real
        // regression rather than assumed to catch it.
        #expect(
            timeRatio < inputRatio * 1.5,
            """
            course tracking grew \(String(format: "%.1f", timeRatio))× for \
            \(String(format: "%.1f", inputRatio))× the points \
            (\(small.count) → \(large.count) points, \
            \(String(format: "%.4f", small.seconds))s → \
            \(String(format: "%.4f", large.seconds))s). Something is scanning \
            the whole course polyline for every fix again.
            """
        )
    }

    /// Course creation is the newest path here and the one a driver waits
    /// on: they finish recording and the app has to hand back a proposal.
    /// The simplification step is Ramer–Douglas–Peucker, whose worst case is
    /// quadratic.
    @Test("building a course from a long recorded drive is not quadratic")
    func courseBuildingIsNotQuadratic() {
        func buildSeconds(segments: Int) -> (seconds: Double, points: Int) {
            let route = Self.longRoute(segments: segments, seed: 91)
            let run = TelemetrySimulator(profile: .fastSmooth, seed: 12).simulate(route: route)
            let recorded = run.gps.map { $0.coordinate }
            let started = Date()
            _ = CourseBuilder.build(
                from: recorded,
                recordedSeconds: run.groundTruth.expectedDurationSeconds
            )
            return (Date().timeIntervalSince(started), recorded.count)
        }

        _ = buildSeconds(segments: 40)   // warm the code paths

        let small = Self.fastest { let r = buildSeconds(segments: 200)
                                   return (r.seconds, r.points) }
        let large = Self.fastest { let r = buildSeconds(segments: 400)
                                   return (r.seconds, r.points) }

        let inputRatio = Double(large.count) / Double(small.count)
        let timeRatio = large.seconds / max(small.seconds, 0.0001)

        #expect(
            timeRatio < inputRatio * 1.6,
            """
            course building grew \(String(format: "%.1f", timeRatio))× for \
            \(String(format: "%.1f", inputRatio))× the points \
            (\(small.count) → \(large.count)).
            """
        )
    }
}
