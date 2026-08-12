import Foundation
import Testing
import SOCore
@testable import SOTelemetry

@Suite("TrajectoryProcessor")
struct TrajectoryProcessorTests {
    private static let start = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    private static let startTime = 1_754_982_000.0

    /// Synthetic 10 Hz straight-line run: `count` samples along a single
    /// great circle, ground-truth spacing `speedMps × 0.1` meters.
    private func straightRun(
        count: Int = 600,
        speedMps: Double = 20,
        bearing: Double = 45,
        accuracy: Double = 5,
        includeSpeed: Bool = true,
        includeCourse: Bool = true
    ) -> [GPSSample] {
        (0..<count).map { i in
            GPSSample(
                timestamp: Self.startTime + Double(i) * 0.1,
                coordinate: Self.start.destination(
                    bearingDegrees: bearing,
                    distanceMeters: Double(i) * speedMps * 0.1
                ),
                horizontalAccuracy: accuracy,
                course: includeCourse ? bearing : nil,
                speed: includeSpeed ? speedMps : nil
            )
        }
    }

    private func groundTruthDistance(count: Int, speedMps: Double = 20) -> Double {
        Double(count - 1) * speedMps * 0.1
    }

    // MARK: Happy path

    @Test("clean 10Hz straight run: nothing rejected, no gaps, distance within 1%")
    func cleanRun() {
        let samples = straightRun()
        let result = TrajectoryProcessor().process(samples)

        #expect(result.points.count == 600)
        #expect(result.rejectedSampleCount == 0)
        #expect(result.gaps.isEmpty)

        let truth = groundTruthDistance(count: 600)
        #expect(abs(result.totalDistanceMeters - truth) <= truth * 0.01)

        for point in result.points {
            #expect(point.speedMps == 20)
            #expect(point.headingDegrees == 45)
        }
        for (a, b) in zip(result.points, result.points.dropFirst()) {
            #expect(b.timestamp > a.timestamp)
            #expect(b.distanceAlongPathMeters >= a.distanceAlongPathMeters)
        }
        #expect(abs(result.duration - 59.9) < 1e-6)
    }

    @Test("processing is deterministic and leaves the input untouched")
    func determinism() {
        let samples = straightRun(count: 100)
        let copy = samples
        let processor = TrajectoryProcessor()
        #expect(processor.process(samples) == processor.process(samples))
        #expect(samples == copy)
    }

    // MARK: Accuracy gate

    @Test("negative and above-threshold accuracy samples are rejected")
    func accuracyGate() {
        var samples = straightRun(count: 100)
        for i in stride(from: 1, to: 100, by: 2) {
            samples[i].horizontalAccuracy = 50
        }
        samples[0].horizontalAccuracy = -1  // invalid fix

        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount == 51)
        #expect(result.points.count == 49)
        #expect(result.points.allSatisfy { $0.horizontalAccuracy == 5 })
        #expect(result.gaps.isEmpty)  // 0.2 s spacing between kept points
    }

    @Test("accuracy exactly at the threshold is kept; just above is rejected")
    func accuracyBoundary() {
        var samples = straightRun(count: 3)
        samples[1].horizontalAccuracy = 30  // == default max, kept
        samples[2].horizontalAccuracy = 30.001  // > max, rejected

        let result = TrajectoryProcessor().process(samples)
        #expect(result.points.count == 2)
        #expect(result.rejectedSampleCount == 1)
        #expect(result.points[1].horizontalAccuracy == 30)
    }

    @Test("all samples inaccurate: empty trajectory, everything rejected")
    func allRejected() {
        let samples = straightRun(count: 50, accuracy: 50)
        let result = TrajectoryProcessor().process(samples)
        #expect(result.points.isEmpty)
        #expect(result.gaps.isEmpty)
        #expect(result.rejectedSampleCount == 50)
        #expect(result.totalDistanceMeters == 0)
        #expect(result.duration == 0)
    }

    // MARK: Teleport gate

    @Test("single 500m teleport is rejected; distance matches the clean run")
    func teleport() {
        let clean = straightRun()
        var samples = clean
        samples[300].coordinate = samples[300].coordinate.destination(
            bearingDegrees: 135, distanceMeters: 500
        )

        let cleanResult = TrajectoryProcessor().process(clean)
        let result = TrajectoryProcessor().process(samples)

        #expect(result.rejectedSampleCount == 1)
        #expect(result.points.count == 599)
        #expect(result.gaps.isEmpty)
        // The kept path skips the teleport, so distance is unchanged.
        #expect(abs(result.totalDistanceMeters - cleanResult.totalDistanceMeters) < 0.5)
    }

    @Test("sustained teleport (walk-away) rejects every displaced sample")
    func sustainedTeleport() {
        var samples = straightRun(count: 100)
        for i in 40..<60 {
            samples[i].coordinate = samples[i].coordinate.destination(
                bearingDegrees: 135, distanceMeters: 500
            )
        }
        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount == 20)
        #expect(result.points.count == 80)
    }

    @Test("implied speed near the plausibility threshold: below kept, above rejected")
    func teleportBoundary() {
        let base = GPSSample(
            timestamp: 1000, coordinate: Self.start, horizontalAccuracy: 5
        )
        func follower(distance: Double) -> GPSSample {
            GPSSample(
                timestamp: 1001,
                coordinate: Self.start.destination(bearingDegrees: 0, distanceMeters: distance),
                horizontalAccuracy: 5
            )
        }
        // dt = 1 s, default maxPlausibleSpeedMps = 90.
        let kept = TrajectoryProcessor().process([base, follower(distance: 89.9)])
        #expect(kept.points.count == 2)
        #expect(kept.rejectedSampleCount == 0)

        let rejected = TrajectoryProcessor().process([base, follower(distance: 90.5)])
        #expect(rejected.points.count == 1)
        #expect(rejected.rejectedSampleCount == 1)
    }

    // MARK: Timestamp gates

    @Test("duplicate timestamp keeps the earliest arrival")
    func duplicateTimestamp() {
        var samples = straightRun(count: 10)
        samples[5].timestamp = samples[4].timestamp  // exact duplicate

        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount == 1)
        #expect(result.points.count == 9)
        #expect(result.points[4].coordinate == samples[4].coordinate)
    }

    @Test(
        "seeded random timestamp corruption: rejected, output strictly increasing",
        arguments: 1...10
    )
    func nonMonotonicTimestamps(seed: Int) {
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
        var samples = straightRun(count: 200)
        let corruptions = Int.random(in: 5...40, using: &rng)
        for _ in 0..<corruptions {
            let index = Int.random(in: 0..<samples.count, using: &rng)
            samples[index].timestamp -= Double.random(in: 0.5...5, using: &rng)
        }

        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount > 0)
        // Every sample is either kept or rejected — never both, never neither.
        #expect(result.points.count + result.rejectedSampleCount == samples.count)
        for (a, b) in zip(result.points, result.points.dropFirst()) {
            #expect(b.timestamp > a.timestamp)
            #expect(b.distanceAlongPathMeters >= a.distanceAlongPathMeters)
        }
    }

    // MARK: Speed and heading derivation

    @Test("missing speed field: derived speeds match the true speed")
    func derivedSpeed() {
        let samples = straightRun(includeSpeed: false, includeCourse: false)
        let result = TrajectoryProcessor().process(samples)

        #expect(result.points[0].speedMps == 0)  // first point has no dt
        for point in result.points.dropFirst() {
            #expect(abs(point.speedMps - 20) < 0.01)
        }
    }

    @Test("negative reported speed falls back to the derived speed")
    func negativeSpeedField() {
        var samples = straightRun(count: 10, includeCourse: false)
        for i in samples.indices {
            samples[i].speed = -1  // CoreLocation-style invalid speed
        }
        let result = TrajectoryProcessor().process(samples)
        #expect(result.points[0].speedMps == 0)
        for point in result.points.dropFirst() {
            #expect(abs(point.speedMps - 20) < 0.01)
        }
    }

    @Test("missing course: heading is derived from the previous kept point")
    func derivedHeading() {
        let samples = straightRun(includeCourse: false)
        let result = TrajectoryProcessor().process(samples)

        #expect(result.points[0].headingDegrees == nil)  // nothing to derive against
        for point in result.points.dropFirst() {
            let heading = point.headingDegrees
            #expect(heading != nil)
            if let heading {
                #expect(abs(heading - 45) < 0.05)
            }
        }
    }

    @Test("stationary without course: heading nil; with course: heading = course")
    func stationaryHeading() {
        let still = (0..<20).map { i in
            GPSSample(
                timestamp: 1000 + Double(i),
                coordinate: Self.start,
                horizontalAccuracy: 5,
                speed: 0
            )
        }
        let result = TrajectoryProcessor().process(still)
        #expect(result.points.count == 20)
        #expect(result.points.allSatisfy { $0.headingDegrees == nil })
        #expect(result.points.allSatisfy { $0.speedMps == 0 })
        #expect(result.totalDistanceMeters == 0)

        var withCourse = still
        for i in withCourse.indices {
            withCourse[i].course = 123
        }
        let courseResult = TrajectoryProcessor().process(withCourse)
        #expect(courseResult.points.allSatisfy { $0.headingDegrees == 123 })
    }

    @Test("heading requires speed strictly above minMovingSpeedMps")
    func headingSpeedBoundary() {
        func pair(speed: Double) -> [GPSSample] {
            [
                GPSSample(
                    timestamp: 1000, coordinate: Self.start,
                    horizontalAccuracy: 5, speed: speed
                ),
                GPSSample(
                    timestamp: 1001,
                    coordinate: Self.start.destination(bearingDegrees: 90, distanceMeters: 2),
                    horizontalAccuracy: 5, speed: speed
                ),
            ]
        }
        // Reported speed exactly at the default threshold (1 m/s): no heading.
        let atThreshold = TrajectoryProcessor().process(pair(speed: 1.0))
        #expect(atThreshold.points[1].headingDegrees == nil)

        // Just above: heading derived.
        let above = TrajectoryProcessor().process(pair(speed: 1.01))
        let heading = above.points[1].headingDegrees
        #expect(heading != nil)
        if let heading {
            #expect(abs(heading - 90) < 0.05)
        }
    }

    // MARK: Gaps

    @Test("dropped 10s window: one .noSamples gap with the kept-point bounds")
    func droppedWindow() {
        let all = straightRun()
        // Remove relative seconds [20, 30): indices 200..<300.
        let samples = all.enumerated().filter { $0.offset < 200 || $0.offset >= 300 }
            .map(\.element)

        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount == 0)
        #expect(result.gaps.count == 1)
        if let gap = result.gaps.first {
            #expect(gap.reason == .noSamples)
            #expect(gap.startTime == all[199].timestamp)
            #expect(gap.endTime == all[300].timestamp)
            #expect(abs(gap.duration - 10.1) < 1e-6)
        }
        // The straight-line path still accumulates full distance across the gap.
        let truth = groundTruthDistance(count: 600)
        #expect(abs(result.totalDistanceMeters - truth) <= truth * 0.01)
    }

    @Test("window of rejected samples: gap reason is .rejectedSamples")
    func rejectedWindow() {
        var samples = straightRun()
        for i in 200..<300 {
            samples[i].horizontalAccuracy = 50
        }
        let result = TrajectoryProcessor().process(samples)
        #expect(result.rejectedSampleCount == 100)
        #expect(result.gaps.count == 1)
        if let gap = result.gaps.first {
            #expect(gap.reason == .rejectedSamples)
            #expect(gap.startTime == samples[199].timestamp)
            #expect(gap.endTime == samples[300].timestamp)
        }
    }

    @Test("dt exactly at the gap threshold is not a gap; above it is")
    func gapBoundary() {
        func run(secondAt dt: Double) -> [GPSSample] {
            [
                GPSSample(timestamp: 1000, coordinate: Self.start, horizontalAccuracy: 5),
                GPSSample(
                    timestamp: 1000 + dt,
                    coordinate: Self.start.destination(bearingDegrees: 0, distanceMeters: 10),
                    horizontalAccuracy: 5
                ),
            ]
        }
        #expect(TrajectoryProcessor().process(run(secondAt: 3.0)).gaps.isEmpty)
        #expect(TrajectoryProcessor().process(run(secondAt: 3.5)).gaps.count == 1)
    }

    // MARK: Degenerate inputs

    @Test("empty input yields an empty trajectory")
    func emptyInput() {
        let result = TrajectoryProcessor().process([])
        #expect(result.points.isEmpty)
        #expect(result.gaps.isEmpty)
        #expect(result.rejectedSampleCount == 0)
        #expect(result.totalDistanceMeters == 0)
        #expect(result.duration == 0)
    }

    @Test("single sample yields a single point with zero distance")
    func singleSample() {
        let sample = GPSSample(
            timestamp: 1000, coordinate: Self.start,
            horizontalAccuracy: 5, course: 200, speed: 12
        )
        let result = TrajectoryProcessor().process([sample])
        #expect(result.points.count == 1)
        #expect(result.gaps.isEmpty)
        #expect(result.rejectedSampleCount == 0)
        if let point = result.points.first {
            #expect(point.speedMps == 12)
            #expect(point.headingDegrees == 200)
            #expect(point.distanceAlongPathMeters == 0)
        }

        var noSpeed = sample
        noSpeed.speed = nil
        noSpeed.course = nil
        let derived = TrajectoryProcessor().process([noSpeed])
        #expect(derived.points.first?.speedMps == 0)
        #expect(derived.points.first?.headingDegrees == nil)
    }

    // MARK: Config

    @Test("custom config thresholds drive the gates, nothing is hard-coded")
    func customConfig() {
        let strict = TrajectoryConfig(
            maxHorizontalAccuracyMeters: 4,
            maxPlausibleSpeedMps: 10,
            gapThresholdSeconds: 0.05,
            minMovingSpeedMps: 25
        )
        let samples = straightRun(count: 20, includeCourse: false)
        let result = TrajectoryProcessor(config: strict).process(samples)
        // accuracy 5 > 4: everything rejected under the strict config.
        #expect(result.points.isEmpty)
        #expect(result.rejectedSampleCount == 20)

        let loose = TrajectoryConfig(
            maxHorizontalAccuracyMeters: 100,
            maxPlausibleSpeedMps: 90,
            gapThresholdSeconds: 0.05,
            minMovingSpeedMps: 25
        )
        let looseResult = TrajectoryProcessor(config: loose).process(samples)
        #expect(looseResult.points.count == 20)
        // Every 0.1 s step now exceeds the 0.05 s gap threshold.
        #expect(looseResult.gaps.count == 19)
        // Speed 20 is below minMovingSpeedMps 25 and there is no course.
        #expect(looseResult.points.allSatisfy { $0.headingDegrees == nil })
    }

    @Test("TrajectoryConfig default values and Codable round-trip")
    func configCodable() throws {
        let config = TrajectoryConfig.default
        #expect(config.maxHorizontalAccuracyMeters == 30)
        #expect(config.maxPlausibleSpeedMps == 90)
        #expect(config.gapThresholdSeconds == 3)
        #expect(config.minMovingSpeedMps == 1)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TrajectoryConfig.self, from: data)
        #expect(decoded == config)
    }
}
