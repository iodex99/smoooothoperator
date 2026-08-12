import Foundation
import SOCore
import SOCourse
import SOIntegrity
import SOModels
import SOScoring
import SOTelemetry

/// Everything the production pipeline concludes about one run. Shared by
/// sogen, the golden regression tests, and (in spirit) the server: the TS
/// implementation must reproduce `GoldenExpected` from the same telemetry.
public struct PipelineOutcome: Sendable {
    public var trajectory: ProcessedTrajectory
    public var confidence: LocationConfidence
    public var events: [DrivingEvent]
    public var integrity: IntegrityReport
    public var score: ScoreResult
    public var gatesHit: Int
    public var deviationDetected: Bool
}

/// The canonical evaluation order used everywhere a run is judged:
/// orientation (interleaved ingestion) → vehicle frames → trajectory →
/// confidence → course tracking → events → integrity → scoring.
public enum RunEvaluationPipeline {
    public static func evaluate(
        gps: [GPSSample],
        imu: [IMUSample],
        route: [GeoCoordinate],
        gates: [Checkpoint],
        benchmarkSeconds: Double,
        scoringConfig: ScoringConfig
    ) -> PipelineOutcome? {
        var estimator = VehicleOrientationEstimator()
        var gpsIndex = 0
        for sample in imu {
            while gpsIndex < gps.count && gps[gpsIndex].timestamp <= sample.timestamp {
                estimator.ingest(gps: gps[gpsIndex])
                gpsIndex += 1
            }
            estimator.ingest(imu: sample)
        }
        while gpsIndex < gps.count {
            estimator.ingest(gps: gps[gpsIndex])
            gpsIndex += 1
        }

        let trajectory = TrajectoryProcessor().process(gps)
        let confidence = LocationConfidenceScorer().assess(raw: gps, trajectory: trajectory)
        let frames = estimator.estimate.map { estimate in imu.map { estimate.transform($0) } } ?? []
        let events = DrivingEventDetector().detect(samples: frames, trajectory: trajectory)

        guard var tracker = CourseProgressTracker(polyline: route, checkpoints: gates) else {
            return nil
        }
        tracker.ingest(trajectory)

        let integrity = RunIntegrityEngine().evaluate(
            rawGPS: gps,
            rawIMU: imu,
            trajectory: trajectory,
            locationConfidence: confidence.score,
            routeAdherence: RouteAdherence(
                expectedGates: gates.count,
                gatesHit: tracker.checkpointHits.count,
                deviationDetected: tracker.deviationDetected
            )
        )

        let score = ScoringEngine(config: scoringConfig).score(
            trajectory: trajectory,
            events: events,
            vehicleFrames: frames,
            benchmarkSeconds: benchmarkSeconds,
            speedLimits: []
        )

        return PipelineOutcome(
            trajectory: trajectory,
            confidence: confidence,
            events: events,
            integrity: integrity,
            score: score,
            gatesHit: tracker.checkpointHits.count,
            deviationDetected: tracker.deviationDetected
        )
    }
}

/// One golden telemetry vector: the full raw input of a simulated run in a
/// compact, cross-language JSON layout (arrays, not keyed objects — the
/// files are committed and size matters). Values are rounded at encode time,
/// so what any consumer reads IS the canonical input.
public struct GoldenTelemetry: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var profile: SimulationProfile
    public var seed: UInt64
    public var benchmarkSeconds: Double
    public var route: [GeoCoordinate]
    public var gates: [Checkpoint]
    public var gps: [GPSSample]
    public var imu: [IMUSample]

    enum CodingKeys: String, CodingKey {
        case formatVersion, profile, seed, benchmarkSeconds, route, gates, gps, imu
    }

    public init(
        formatVersion: Int = 1,
        profile: SimulationProfile,
        seed: UInt64,
        benchmarkSeconds: Double,
        route: [GeoCoordinate],
        gates: [Checkpoint],
        gps: [GPSSample],
        imu: [IMUSample]
    ) {
        self.formatVersion = formatVersion
        self.profile = profile
        self.seed = seed
        self.benchmarkSeconds = benchmarkSeconds
        self.route = route
        self.gates = gates
        self.gps = gps
        self.imu = imu
    }

    /// Sentinel for "nil" in numeric array slots (never a legal value there).
    private static let absent = -9999.0

    private static func round(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10, Double(decimals))
        return (value * factor).rounded() / factor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(profile, forKey: .profile)
        try container.encode(seed, forKey: .seed)
        try container.encode(Self.round(benchmarkSeconds, decimals: 3), forKey: .benchmarkSeconds)
        try container.encode(
            route.map { [Self.round($0.latitude, decimals: 7), Self.round($0.longitude, decimals: 7)] },
            forKey: .route
        )
        try container.encode(
            gates.map {
                [Double($0.sequence),
                 Self.round($0.center.latitude, decimals: 7),
                 Self.round($0.center.longitude, decimals: 7),
                 Self.round($0.radiusMeters, decimals: 1)]
            },
            forKey: .gates
        )
        try container.encode(
            gps.map { sample in
                [Self.round(sample.timestamp, decimals: 4),
                 Self.round(sample.coordinate.latitude, decimals: 7),
                 Self.round(sample.coordinate.longitude, decimals: 7),
                 Self.round(sample.horizontalAccuracy, decimals: 2),
                 sample.course.map { Self.round($0, decimals: 2) } ?? Self.absent,
                 sample.speed.map { Self.round($0, decimals: 3) } ?? Self.absent,
                 sample.altitude.map { Self.round($0, decimals: 1) } ?? Self.absent]
            },
            forKey: .gps
        )
        try container.encode(
            imu.map { sample in
                [Self.round(sample.timestamp, decimals: 4),
                 Self.round(sample.accelX, decimals: 6),
                 Self.round(sample.accelY, decimals: 6),
                 Self.round(sample.accelZ, decimals: 6),
                 Self.round(sample.gyroX, decimals: 6),
                 Self.round(sample.gyroY, decimals: 6),
                 Self.round(sample.gyroZ, decimals: 6)]
            },
            forKey: .imu
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        profile = try container.decode(SimulationProfile.self, forKey: .profile)
        seed = try container.decode(UInt64.self, forKey: .seed)
        benchmarkSeconds = try container.decode(Double.self, forKey: .benchmarkSeconds)
        route = try container.decode([[Double]].self, forKey: .route).map {
            GeoCoordinate(latitude: $0[0], longitude: $0[1])
        }
        gates = try container.decode([[Double]].self, forKey: .gates).map {
            Checkpoint(sequence: Int($0[0]),
                       center: GeoCoordinate(latitude: $0[1], longitude: $0[2]),
                       radiusMeters: $0[3])
        }
        gps = try container.decode([[Double]].self, forKey: .gps).map {
            GPSSample(
                timestamp: $0[0],
                coordinate: GeoCoordinate(latitude: $0[1], longitude: $0[2]),
                altitude: $0[6] == Self.absent ? nil : $0[6],
                horizontalAccuracy: $0[3],
                course: $0[4] == Self.absent ? nil : $0[4],
                speed: $0[5] == Self.absent ? nil : $0[5]
            )
        }
        imu = try container.decode([[Double]].self, forKey: .imu).map {
            IMUSample(timestamp: $0[0],
                      accelX: $0[1], accelY: $0[2], accelZ: $0[3],
                      gyroX: $0[4], gyroY: $0[5], gyroZ: $0[6])
        }
    }
}

/// The discrete pipeline outputs a golden vector pins. Every field is an
/// integer, string, or bool — byte-exact comparable across Swift and TS.
public struct GoldenExpected: Codable, Sendable, Equatable {
    public var scoringVersion: String
    public var verdict: String
    public var finalScore: Int
    public var paceBps: Int
    public var smoothnessBps: Int
    public var controlBps: Int
    public var complianceBps: Int
    public var confidenceScore: Int
    public var eventCounts: [String: Int]
    /// Sorted, de-duplicated integrity flags.
    public var flags: [String]
    public var gatesHit: Int
    public var deviationDetected: Bool
    public var hasComplianceData: Bool

    public init(outcome: PipelineOutcome) {
        scoringVersion = outcome.score.scoringVersion
        verdict = outcome.integrity.verdict.rawValue
        finalScore = outcome.score.finalScore
        paceBps = outcome.score.breakdown.paceBps
        smoothnessBps = outcome.score.breakdown.smoothnessBps
        controlBps = outcome.score.breakdown.controlBps
        complianceBps = outcome.score.breakdown.complianceBps
        confidenceScore = outcome.confidence.score
        eventCounts = outcome.events.reduce(into: [:]) { counts, event in
            counts[event.kind.rawValue, default: 0] += 1
        }
        flags = Set(outcome.integrity.findings.map(\.flag.rawValue)).sorted()
        gatesHit = outcome.gatesHit
        deviationDetected = outcome.deviationDetected
        hasComplianceData = outcome.score.hasComplianceData
    }
}

/// Builds golden (telemetry, expected) pairs. The expected side is computed
/// from the encode→decode round trip of the telemetry, so it corresponds to
/// the FILE content exactly — not to unrounded in-memory values.
public enum GoldenVectorFactory {
    /// Compact course for golden vectors: calibration straight + a hairpin
    /// cluster + sweepers, ~1.5 km — big enough to exercise everything,
    /// small enough to commit.
    public static func goldenRoute(seed: UInt64) -> [GeoCoordinate] {
        var rng = SeededRandomNumberGenerator(seed: seed)
        var route = [GeoCoordinate(latitude: 34.0259, longitude: -118.7798)]
        var heading = 40.0
        for _ in 0..<4 {  // 400 m calibration straight
            route.append(route[route.count - 1].destination(bearingDegrees: heading, distanceMeters: 100))
        }
        for segment in 0..<8 {
            let turn: Double
            let length: Double
            if (3...5).contains(segment) {  // hairpin cluster
                turn = Double.random(in: 42...55, using: &rng)
                length = Double.random(in: 50...70, using: &rng)
            } else {
                turn = Double.random(in: -35...35, using: &rng)
                length = Double.random(in: 120...220, using: &rng)
            }
            heading += turn
            route.append(route[route.count - 1].destination(bearingDegrees: heading, distanceMeters: length))
        }
        return route
    }

    /// Emission config for goldens: reduced rates keep committed files small
    /// while every check stays exercised (all thresholds are time-based).
    public static let goldenSimulationConfig: SimulationConfig = {
        var config = SimulationConfig.default
        config.gpsHz = 5
        config.imuHz = 25
        return config
    }()

    public static let routeSeed: UInt64 = 4747

    /// The reference benchmark for the golden course (spec §57): a strong
    /// fastSmooth time, slightly tightened.
    public static func benchmarkSeconds() -> Double {
        let route = goldenRoute(seed: routeSeed)
        let duration = TelemetrySimulator(
            profile: .fastSmooth, seed: 100, config: goldenSimulationConfig
        ).simulate(route: route).groundTruth.expectedDurationSeconds
        return duration * 0.97
    }

    public static func gates(route: [GeoCoordinate]) -> [Checkpoint] {
        [0, route.count / 3, 2 * route.count / 3, route.count - 1].enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 40)
        }
    }

    /// Simulates, rounds through the wire format, evaluates, and returns the
    /// (telemetry, expected) pair ready to be written.
    public static func make(
        profile: SimulationProfile,
        seed: UInt64,
        scoringConfig: ScoringConfig
    ) throws -> (telemetry: GoldenTelemetry, expected: GoldenExpected) {
        let route = goldenRoute(seed: routeSeed)
        let run = TelemetrySimulator(profile: profile, seed: seed, config: goldenSimulationConfig)
            .simulate(route: route)

        let raw = GoldenTelemetry(
            profile: profile,
            seed: seed,
            benchmarkSeconds: benchmarkSeconds(),
            route: route,
            gates: gates(route: route),
            gps: run.gps,
            imu: run.imu
        )
        // Round-trip so `expected` matches what consumers read from disk.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let telemetry = try JSONDecoder().decode(GoldenTelemetry.self, from: try encoder.encode(raw))

        guard let outcome = RunEvaluationPipeline.evaluate(
            gps: telemetry.gps,
            imu: telemetry.imu,
            route: telemetry.route,
            gates: telemetry.gates,
            benchmarkSeconds: telemetry.benchmarkSeconds,
            scoringConfig: scoringConfig
        ) else {
            throw GoldenVectorError.degenerateCourse
        }
        return (telemetry, GoldenExpected(outcome: outcome))
    }
}

public enum GoldenVectorError: Error {
    case degenerateCourse
}
