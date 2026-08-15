import Foundation
import Testing
import SOCore
import SOCourse
import SOModels
import SOScoring
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
/// These tests do not assert a time in milliseconds — that would be a
/// flaky test on shared CI hardware. They assert the SHAPE: quadruple the
/// input and the work must not grow like the square. A quadratic step shows
/// up as 16× and cannot hide inside the slack these allow.
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
        // Warm the code paths so the first measurement is not paying for
        // one-time work that has nothing to do with input size.
        _ = Self.evaluationSeconds(segments: 20)

        let small = Self.evaluationSeconds(segments: 40)
        let large = Self.evaluationSeconds(segments: 160)

        let inputRatio = Double(large.samples) / Double(small.samples)
        let timeRatio = large.seconds / max(small.seconds, 0.0001)

        // 4× the input. Linear is ~4×, quadratic is ~16×. The bar is 8×:
        // generous enough for cache effects and a loaded CI box, far below
        // anything quadratic.
        #expect(
            timeRatio < inputRatio * 2,
            """
            evaluation time grew \(String(format: "%.1f", timeRatio))× for \
            \(String(format: "%.1f", inputRatio))× the samples \
            (\(small.samples) → \(large.samples) samples, \
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

        _ = buildSeconds(segments: 20)
        let small = buildSeconds(segments: 40)
        let large = buildSeconds(segments: 160)

        let inputRatio = Double(large.points) / Double(small.points)
        let timeRatio = large.seconds / max(small.seconds, 0.0001)

        #expect(
            timeRatio < inputRatio * 2,
            """
            course building grew \(String(format: "%.1f", timeRatio))× for \
            \(String(format: "%.1f", inputRatio))× the points \
            (\(small.points) → \(large.points)).
            """
        )
    }
}
