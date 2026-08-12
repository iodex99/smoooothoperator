import Foundation
import Testing
import SOCore
import SOCourse
import SOModels
import SOTelemetry
@testable import SOScoring

@Suite("ScoringEngine")
struct ScoringEngineTests {
    let base = 1_754_982_000.0
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)

    /// The canonical repo config — the same file the TS scorer loads.
    static let repoConfig: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SOScoringTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SmoooothKit
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    var engine: ScoringEngine { ScoringEngine(config: Self.repoConfig) }

    /// Straight-line trajectory: `durationSeconds` at constant speed over
    /// `distanceMeters`.
    private func makeTrajectory(distanceMeters: Double, durationSeconds: Double) -> ProcessedTrajectory {
        let steps = 100
        let speed = distanceMeters / durationSeconds
        let points = (0...steps).map { step -> TrajectoryPoint in
            let fraction = Double(step) / Double(steps)
            return TrajectoryPoint(
                timestamp: base + fraction * durationSeconds,
                coordinate: origin.destination(bearingDegrees: 0, distanceMeters: fraction * distanceMeters),
                speedMps: speed,
                headingDegrees: 0,
                distanceAlongPathMeters: fraction * distanceMeters,
                horizontalAccuracy: 5
            )
        }
        return ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0)
    }

    private func makeEvent(_ kind: DrivingEventKind, at time: Double = 0, peak: Double = 0.4) -> DrivingEvent {
        DrivingEvent(kind: kind, startTime: base + time, endTime: base + time + 1,
                     peakMagnitudeG: peak, speedAtPeakMps: 15)
    }

    private func score(
        trajectory: ProcessedTrajectory? = nil,
        events: [DrivingEvent] = [],
        frames: [VehicleFrameSample] = [],
        benchmark: Double = 600,
        limits: [SpeedLimitSegment] = []
    ) -> ScoreResult {
        engine.score(
            trajectory: trajectory ?? makeTrajectory(distanceMeters: 10_000, durationSeconds: 600),
            events: events,
            vehicleFrames: frames,
            benchmarkSeconds: benchmark,
            speedLimits: limits
        )
    }

    // MARK: - Config

    @Test("the canonical repo config loads and validates")
    func repoConfigLoads() {
        #expect(Self.repoConfig.version == "1.0.0")
        #expect(Self.repoConfig.isValid)
    }

    @Test("structurally invalid configs are rejected at load")
    func invalidConfigRejected() {
        var broken = Self.repoConfig
        broken.weights = ScoringWeights(paceBps: 5000, smoothnessBps: 5000, controlBps: 500, complianceBps: 500)
        let data = try! JSONEncoder().encode(broken)
        #expect(throws: ScoringConfigError.invalidConfig) {
            _ = try ScoringConfig.load(from: data)
        }
    }

    // MARK: - Pace

    @Test("pace hits the curve exactly", arguments: [
        (600.0, 9000),    // ratio 1.0 → 9000
        (510.0, 10000),   // ratio 0.85 → clamp top
        (720.0, 6500),    // ratio 1.2
        (900.0, 3500),    // ratio 1.5
        (1800.0, 500),    // ratio 3.0 → clamp bottom
    ])
    func paceCurve(duration: Double, expected: Int) {
        let result = score(trajectory: makeTrajectory(distanceMeters: 10_000, durationSeconds: duration))
        #expect(result.breakdown.paceBps == expected)
    }

    @Test("slower never scores better pace (monotonicity)")
    func paceMonotone() {
        var previous = Int.max
        for duration in stride(from: 500.0, through: 1600, by: 50) {
            let pace = score(trajectory: makeTrajectory(distanceMeters: 10_000, durationSeconds: duration))
                .breakdown.paceBps
            #expect(pace <= previous)
            previous = pace
        }
    }

    // MARK: - Smoothness

    @Test("a clean run scores perfect smoothness")
    func cleanSmoothness() {
        #expect(score().breakdown.smoothnessBps == 10_000)
    }

    @Test("smoothness reflects weighted events per km exactly")
    func smoothnessEvents() {
        // 10 hardBraking events × weight 4.0 over 10 km = 4.0 weighted/km
        // → curve(4.0) = 7500 + (4-3)/(6-3)·(5000-7500) = 6666.67 → 6667.
        // Event component 6000 bps, jerk component (RMS 0 → 10000) 4000 bps:
        // (6667×6000 + 10000×4000)/10000 = 8000 (truncated from 8000.2).
        let events = (0..<10).map { makeEvent(.hardBraking, at: Double($0) * 30) }
        let result = score(events: events)
        #expect(result.breakdown.smoothnessBps == 8000)
    }

    @Test("every added hard event can only lower smoothness (monotonicity)")
    func smoothnessMonotone() {
        var events: [DrivingEvent] = []
        var previous = Int.max
        for index in 0..<15 {
            events.append(makeEvent(.hardBraking, at: Double(index) * 30))
            let smoothness = score(events: events).breakdown.smoothnessBps
            #expect(smoothness <= previous)
            previous = smoothness
        }
    }

    @Test("jerky vehicle frames lower smoothness")
    func jerkComponent() {
        // 0.3g swings every 0.1s → |jerk| = 3 g/s → RMS 3 → curve clamps to 1000.
        let frames = (0..<600).map { index in
            VehicleFrameSample(
                timestamp: base + Double(index) * 0.1,
                longitudinal: index % 2 == 0 ? 0.15 : -0.15,
                lateral: 0, vertical: 0, yawRate: 0
            )
        }
        let jerky = score(frames: frames).breakdown.smoothnessBps
        let calm = score().breakdown.smoothnessBps
        #expect(jerky < calm)
        // event 10000×6000 + jerk 1000×4000 → 6400
        #expect(jerky == 6400)
    }

    // MARK: - Control

    @Test("consistent event peaks score better control than scattered ones")
    func controlConsistency() {
        let consistent = (0..<6).map { makeEvent(.braking, at: Double($0) * 60, peak: 0.30) }
        let scattered = [0.20, 0.45, 0.28, 0.55, 0.22, 0.60].enumerated().map { index, peak in
            makeEvent(.braking, at: Double(index) * 60, peak: peak)
        }
        let consistentScore = score(events: consistent).breakdown.controlBps
        let scatteredScore = score(events: scattered).breakdown.controlBps
        #expect(consistentScore > scatteredScore)
    }

    @Test("throttle pumping lowers control via the oscillation component")
    func oscillation() {
        // Sign flip every second, well above the deadband.
        let frames = (0..<600).map { index in
            VehicleFrameSample(
                timestamp: base + Double(index),
                longitudinal: index % 2 == 0 ? 0.1 : -0.1,
                lateral: 0, vertical: 0, yawRate: 0
            )
        }
        let pumping = score(frames: frames).breakdown.controlBps
        let calm = score().breakdown.controlBps
        #expect(pumping < calm)
    }

    // MARK: - Compliance

    @Test("no speed-limit data yields the neutral no-data score, flagged")
    func complianceNoData() {
        let result = score()
        #expect(result.breakdown.complianceBps == 10_000)
        #expect(!result.hasComplianceData)
    }

    @Test("legal driving with data scores full compliance, flagged as real")
    func complianceLegal() {
        // 10 km at 16.67 m/s under a 20 m/s limit.
        let limits = [SpeedLimitSegment(startDistanceMeters: 0, endDistanceMeters: 10_000, limitMps: 20)]
        let result = score(limits: limits)
        #expect(result.breakdown.complianceBps == 10_000)
        #expect(result.hasComplianceData)
    }

    @Test("speeding lowers compliance exactly per the exceedance curve")
    func complianceSpeeding() {
        // 10 km in 400 s = 25 m/s against a 20 m/s limit everywhere:
        // over = 25 − 20 − 1 = 4; index = 4/20 = 0.2
        // → curve: 2000 + (0.2−0.15)/(0.3−0.15)·(0−2000) = 1333.33… → 1333.
        let limits = [SpeedLimitSegment(startDistanceMeters: 0, endDistanceMeters: 10_000, limitMps: 20)]
        let result = score(trajectory: makeTrajectory(distanceMeters: 10_000, durationSeconds: 400), limits: limits)
        #expect(result.breakdown.complianceBps == 1333)
        #expect(result.hasComplianceData)
    }

    @Test("more speeding never raises compliance (monotonicity)")
    func complianceMonotone() {
        let limits = [SpeedLimitSegment(startDistanceMeters: 0, endDistanceMeters: 10_000, limitMps: 20)]
        var previous = Int.max
        for duration in stride(from: 700.0, through: 250, by: -50) {
            let compliance = score(
                trajectory: makeTrajectory(distanceMeters: 10_000, durationSeconds: duration),
                limits: limits
            ).breakdown.complianceBps
            #expect(compliance <= previous)
            previous = compliance
        }
    }

    // MARK: - Bounds & determinism

    @Test("all scores stay in bounds under randomized inputs", arguments: 1...15)
    func boundsProperty(seed: Int) {
        var rng = SeededRandomNumberGenerator(seed: UInt64(seed))
        let duration = Double.random(in: 60...3600, using: &rng)
        let distance = Double.random(in: 500...50_000, using: &rng)
        let events = (0..<Int.random(in: 0...40, using: &rng)).map { index in
            makeEvent(
                DrivingEventKind.allCases.randomElement(using: &rng)!,
                at: Double(index) * 10,
                peak: Double.random(in: 0.2...0.9, using: &rng)
            )
        }
        let limits = Bool.random(using: &rng)
            ? [SpeedLimitSegment(startDistanceMeters: 0, endDistanceMeters: distance,
                                 limitMps: Double.random(in: 8...40, using: &rng))]
            : []
        let result = score(
            trajectory: makeTrajectory(distanceMeters: distance, durationSeconds: duration),
            events: events,
            benchmark: Double.random(in: 60...3600, using: &rng),
            limits: limits
        )
        for value in [result.breakdown.paceBps, result.breakdown.smoothnessBps,
                      result.breakdown.controlBps, result.breakdown.complianceBps,
                      result.finalScore] {
            #expect(value >= 0 && value <= 10_000)
        }
        #expect(result.scoringVersion == "1.0.0")
    }

    @Test("scoring is deterministic")
    func deterministic() {
        let events = [makeEvent(.hardBraking), makeEvent(.cornering, at: 60)]
        let first = score(events: events)
        let second = score(events: events)
        #expect(first == second)
    }
}
