import Foundation
import Testing
import SOCore
@testable import SOTelemetry

@Suite("LocationConfidence")
struct LocationConfidenceTests {
    private static let start = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    private static let startTime = 1_754_982_000.0

    /// Synthetic 10 Hz straight-line run (same shape as the processor tests;
    /// duplicated privately so test files stay independent).
    private func straightRun(
        count: Int = 600,
        speedMps: Double = 20,
        bearing: Double = 45,
        accuracy: Double = 5
    ) -> [GPSSample] {
        (0..<count).map { i in
            GPSSample(
                timestamp: Self.startTime + Double(i) * 0.1,
                coordinate: Self.start.destination(
                    bearingDegrees: bearing,
                    distanceMeters: Double(i) * speedMps * 0.1
                ),
                horizontalAccuracy: accuracy,
                course: bearing,
                speed: speedMps
            )
        }
    }

    private func assess(
        _ samples: [GPSSample],
        config: LocationConfidenceConfig = .default
    ) -> LocationConfidence {
        let trajectory = TrajectoryProcessor().process(samples)
        return LocationConfidenceScorer(config: config).assess(raw: samples, trajectory: trajectory)
    }

    // MARK: Happy path

    @Test("clean 10Hz straight run scores at least 90")
    func cleanRunConfidence() {
        let confidence = assess(straightRun())
        #expect(confidence.score >= 90)
        #expect(confidence.accuracyScore == 100)
        #expect(confidence.continuityScore == 100)
        #expect(confidence.plausibilityScore == 100)
    }

    @Test("assessment is deterministic")
    func determinism() {
        let samples = straightRun(count: 200)
        let trajectory = TrajectoryProcessor().process(samples)
        let scorer = LocationConfidenceScorer()
        let first = scorer.assess(raw: samples, trajectory: trajectory)
        let second = scorer.assess(raw: samples, trajectory: trajectory)
        #expect(first == second)
    }

    // MARK: Component responses

    @Test("teleport injection drops the plausibility sub-score")
    func teleportPlausibility() {
        let clean = straightRun()
        var teleport = clean
        teleport[300].coordinate = teleport[300].coordinate.destination(
            bearingDegrees: 135, distanceMeters: 500
        )

        let cleanConfidence = assess(clean)
        let teleportConfidence = assess(teleport)

        #expect(teleportConfidence.plausibilityScore < cleanConfidence.plausibilityScore)
        #expect(teleportConfidence.score <= cleanConfidence.score)
        // A single bad fix should not tank accuracy or continuity.
        #expect(teleportConfidence.continuityScore == cleanConfidence.continuityScore)
    }

    @Test("accuracy degradation drives the accuracy sub-score down")
    func accuracyDegradation() {
        var mixed = straightRun()
        for i in stride(from: 1, to: mixed.count, by: 2) {
            mixed[i].horizontalAccuracy = 50  // rejected by the processor
        }
        let trajectory = TrajectoryProcessor().process(mixed)
        #expect(trajectory.rejectedSampleCount == 300)

        let confidence = LocationConfidenceScorer().assess(raw: mixed, trajectory: trajectory)
        // Mean raw accuracy (5 + 50)/2 = 27.5 m sits low on the default curve.
        #expect(confidence.accuracyScore < 60)
        #expect(confidence.accuracyScore < assess(straightRun()).accuracyScore)
        #expect(confidence.score < 90)
    }

    @Test("all samples inaccurate: empty trajectory means all-zero confidence")
    func fullyDegraded() {
        let samples = straightRun(count: 100, accuracy: 50)
        let confidence = assess(samples)
        #expect(confidence == LocationConfidence(
            score: 0, accuracyScore: 0, continuityScore: 0, plausibilityScore: 0
        ))
    }

    @Test("a dropped 10s window drops the continuity sub-score")
    func droppedWindowContinuity() {
        let all = straightRun()
        let gappy = all.enumerated().filter { $0.offset < 200 || $0.offset >= 300 }
            .map(\.element)

        let cleanConfidence = assess(all)
        let gappyConfidence = assess(gappy)

        #expect(gappyConfidence.continuityScore < cleanConfidence.continuityScore)
        #expect(gappyConfidence.continuityScore < 60)  // ~17% of the run is missing
        #expect(gappyConfidence.score < cleanConfidence.score)
        // Nothing was rejected, so plausibility stays untouched.
        #expect(gappyConfidence.plausibilityScore == 100)
    }

    // MARK: Degenerate inputs

    @Test("empty raw samples yield all-zero confidence")
    func emptyRaw() {
        let empty = ProcessedTrajectory(points: [], gaps: [], rejectedSampleCount: 0)
        let confidence = LocationConfidenceScorer().assess(raw: [], trajectory: empty)
        #expect(confidence == LocationConfidence(
            score: 0, accuracyScore: 0, continuityScore: 0, plausibilityScore: 0
        ))
    }

    @Test("non-empty raw with an empty trajectory yields all-zero confidence")
    func emptyTrajectory() {
        let raw = straightRun(count: 5)
        let empty = ProcessedTrajectory(points: [], gaps: [], rejectedSampleCount: 5)
        let confidence = LocationConfidenceScorer().assess(raw: raw, trajectory: empty)
        #expect(confidence == LocationConfidence(
            score: 0, accuracyScore: 0, continuityScore: 0, plausibilityScore: 0
        ))
    }

    @Test("single-sample run: zero duration means no gap penalty")
    func singleSample() {
        let samples = [
            GPSSample(
                timestamp: 1000, coordinate: Self.start,
                horizontalAccuracy: 5, speed: 0
            )
        ]
        let confidence = assess(samples)
        #expect(confidence.continuityScore == 100)
        #expect(confidence.accuracyScore == 100)
        #expect(confidence.plausibilityScore == 100)
        #expect((0...100).contains(confidence.score))
    }

    // MARK: Property — score bounds over seeded random inputs

    @Test(
        "all scores stay in 0...100 over seeded random clean/corrupt inputs",
        arguments: 0..<24
    )
    func scoreBounds(seed: Int) {
        // Even seeds: clean runs of varying shapes. Odd seeds: corrupt chaos.
        let samples: [GPSSample] =
            if seed.isMultiple(of: 2) {
                straightRun(
                    count: 50 + seed * 20,
                    speedMps: Double(5 + seed),
                    bearing: Double(seed * 15),
                    accuracy: Double(2 + seed)
                )
            } else {
                Self.randomRun(seed: UInt64(seed))
            }

        let trajectory = TrajectoryProcessor().process(samples)
        let confidence = LocationConfidenceScorer().assess(raw: samples, trajectory: trajectory)

        #expect((0...100).contains(confidence.score))
        #expect((0...100).contains(confidence.accuracyScore))
        #expect((0...100).contains(confidence.continuityScore))
        #expect((0...100).contains(confidence.plausibilityScore))

        // Processor invariants must also hold on arbitrary input.
        #expect(trajectory.points.count + trajectory.rejectedSampleCount == samples.count)
        for (a, b) in zip(trajectory.points, trajectory.points.dropFirst()) {
            #expect(b.timestamp > a.timestamp)
            #expect(b.distanceAlongPathMeters >= a.distanceAlongPathMeters)
        }
    }

    /// Deterministic corrupt run: jittered/regressing timestamps, occasional
    /// teleports, accuracy from invalid (negative) to hopeless.
    private static func randomRun(seed: UInt64) -> [GPSSample] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        let count = Int.random(in: 0...240, using: &rng)
        var coordinate = GeoCoordinate(
            latitude: Double.random(in: -60...60, using: &rng),
            longitude: Double.random(in: -179...179, using: &rng)
        )
        var timestamp = Double.random(in: 0...2_000_000_000, using: &rng)
        var samples: [GPSSample] = []
        for _ in 0..<count {
            timestamp += Double.random(in: -0.2...0.4, using: &rng)
            let teleports = Double.random(in: 0...1, using: &rng) < 0.05
            coordinate = coordinate.destination(
                bearingDegrees: Double.random(in: 0..<360, using: &rng),
                distanceMeters: teleports
                    ? Double.random(in: 400...2000, using: &rng)
                    : Double.random(in: 0...4, using: &rng)
            )
            samples.append(
                GPSSample(
                    timestamp: timestamp,
                    coordinate: coordinate,
                    horizontalAccuracy: Double.random(in: -5...60, using: &rng),
                    course: Bool.random(using: &rng)
                        ? Double.random(in: 0..<360, using: &rng) : nil,
                    speed: Bool.random(using: &rng)
                        ? Double.random(in: -2...50, using: &rng) : nil
                ))
        }
        return samples
    }

    // MARK: Config-driven behavior

    @Test("integer weighting mirrors ScoreBreakdown: sum(component×weight)/100")
    func integerWeighting() throws {
        // Constant curves pin each sub-score so the combination is exact.
        let config = LocationConfidenceConfig(
            meanAccuracyCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: 80)])),
            gapFractionCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: 60)])),
            rejectionRateCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: 40)])),
            accuracyWeight: 50,
            continuityWeight: 30,
            plausibilityWeight: 20
        )
        let confidence = assess(straightRun(count: 50), config: config)
        #expect(confidence.accuracyScore == 80)
        #expect(confidence.continuityScore == 60)
        #expect(confidence.plausibilityScore == 40)
        #expect(confidence.score == (80 * 50 + 60 * 30 + 40 * 20) / 100)  // 66
    }

    @Test("out-of-range curve outputs are clamped to 0...100")
    func curveClamping() throws {
        let config = LocationConfidenceConfig(
            meanAccuracyCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: 150)])),
            gapFractionCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: -20)])),
            rejectionRateCurve: try #require(
                PiecewiseLinearCurve(breakpoints: [.init(x: 0, y: 50)])),
            accuracyWeight: 40,
            continuityWeight: 30,
            plausibilityWeight: 30
        )
        let confidence = assess(straightRun(count: 50), config: config)
        #expect(confidence.accuracyScore == 100)
        #expect(confidence.continuityScore == 0)
        #expect(confidence.plausibilityScore == 50)
        #expect((0...100).contains(confidence.score))
    }

    @Test("default config weights are valid and sum to 100")
    func defaultConfigValid() {
        let config = LocationConfidenceConfig.default
        #expect(config.weightsAreValid)
        #expect(
            config.accuracyWeight + config.continuityWeight + config.plausibilityWeight == 100)

        var broken = config
        broken.accuracyWeight = 41
        #expect(!broken.weightsAreValid)
        var negative = config
        negative.accuracyWeight = -10
        negative.continuityWeight = 80
        #expect(!negative.weightsAreValid)
    }

    // MARK: Codable

    @Test("LocationConfidenceConfig Codable round-trip")
    func configCodable() throws {
        let config = LocationConfidenceConfig.default
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(LocationConfidenceConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("LocationConfidence Codable round-trip")
    func confidenceCodable() throws {
        let confidence = LocationConfidence(
            score: 87, accuracyScore: 91, continuityScore: 100, plausibilityScore: 70
        )
        let data = try JSONEncoder().encode(confidence)
        let decoded = try JSONDecoder().decode(LocationConfidence.self, from: data)
        #expect(decoded == confidence)
    }
}
