import Foundation
import SOCore
import SOCourse
import SOModels
import SOTelemetry

/// The scored result of a run. `scoringVersion` is stamped so historical
/// runs keep the scoring they earned (spec §43).
public struct ScoreResult: Codable, Sendable, Equatable {
    public var breakdown: ScoreBreakdown
    public var finalScore: Int
    public var scoringVersion: String
    /// True when compliance was scored from real speed-limit data rather
    /// than the no-data default (spec §41).
    public var hasComplianceData: Bool
    /// Raw metric values behind each sub-score — for result screens and
    /// cross-implementation tracing; never re-used in score math.
    public var metrics: [String: Double]

    public init(
        breakdown: ScoreBreakdown,
        finalScore: Int,
        scoringVersion: String,
        hasComplianceData: Bool,
        metrics: [String: Double]
    ) {
        self.breakdown = breakdown
        self.finalScore = finalScore
        self.scoringVersion = scoringVersion
        self.hasComplianceData = hasComplianceData
        self.metrics = metrics
    }
}

/// Computes the four sub-scores and the final score (spec §§38–42).
///
/// Everything is driven by `ScoringConfig` curves — the engine contains
/// mechanics, never tuning. Cross-language determinism: curve lookups and
/// `+ − × ÷ √` only; quantization to integer bps via half-up rounding before
/// integer-weighted combination with truncating division. The TypeScript
/// port mirrors the operation order exactly (xval-enforced).
public struct ScoringEngine: Sendable {
    public let config: ScoringConfig

    public init(config: ScoringConfig) {
        self.config = config
    }

    /// Scores a completed run.
    /// - Parameters:
    ///   - trajectory: processed trajectory (never raw GPS).
    ///   - events: detected driving events.
    ///   - vehicleFrames: vehicle-frame IMU (empty ⇒ jerk/oscillation fall
    ///     back to their curve values at 0 — the confidence system, not
    ///     scoring, penalizes missing sensors).
    ///   - benchmarkSeconds: course reference benchmark (spec §57).
    ///   - speedLimits: distance-keyed limits; empty ⇒ compliance no-data.
    public func score(
        trajectory: ProcessedTrajectory,
        events: [DrivingEvent],
        vehicleFrames: [VehicleFrameSample],
        benchmarkSeconds: Double,
        speedLimits: [SpeedLimitSegment]
    ) -> ScoreResult {
        var metrics: [String: Double] = [:]

        let pace = paceScore(trajectory: trajectory, benchmarkSeconds: benchmarkSeconds, metrics: &metrics)
        let smoothness = smoothnessScore(trajectory: trajectory, events: events, vehicleFrames: vehicleFrames, metrics: &metrics)
        let control = controlScore(events: events, vehicleFrames: vehicleFrames, metrics: &metrics)
        let (compliance, hasData) = complianceScore(trajectory: trajectory, speedLimits: speedLimits, metrics: &metrics)

        let breakdown = ScoreBreakdown(
            paceBps: pace,
            smoothnessBps: smoothness,
            controlBps: control,
            complianceBps: compliance
        )
        return ScoreResult(
            breakdown: breakdown,
            finalScore: breakdown.finalScore(weights: config.weights),
            scoringVersion: config.version,
            hasComplianceData: hasData,
            metrics: metrics
        )
    }

    // MARK: - Pace (spec §39)

    private func paceScore(
        trajectory: ProcessedTrajectory,
        benchmarkSeconds: Double,
        metrics: inout [String: Double]
    ) -> Int {
        guard benchmarkSeconds > 0, trajectory.duration > 0 else { return 0 }
        let ratio = trajectory.duration / benchmarkSeconds
        metrics["paceBenchmarkRatio"] = ratio
        return quantize(config.pace.benchmarkRatioCurve.value(at: ratio))
    }

    // MARK: - Smoothness (spec §38)

    private func smoothnessScore(
        trajectory: ProcessedTrajectory,
        events: [DrivingEvent],
        vehicleFrames: [VehicleFrameSample],
        metrics: inout [String: Double]
    ) -> Int {
        let kilometers = max(trajectory.totalDistanceMeters / 1000, 0.001)
        var weightedEvents = 0.0
        for event in events {
            weightedEvents += config.smoothness.eventWeights[event.kind.rawValue] ?? 1.0
        }
        let eventsPerKm = weightedEvents / kilometers
        metrics["smoothnessWeightedEventsPerKm"] = eventsPerKm
        let eventScore = config.smoothness.weightedEventsPerKmCurve.value(at: eventsPerKm)

        let jerkRMS = longitudinalJerkRMS(vehicleFrames)
        metrics["smoothnessJerkRMS"] = jerkRMS
        let jerkScore = config.smoothness.jerkRMSCurve.value(at: jerkRMS)

        return combine([
            (quantize(eventScore), config.smoothness.eventComponentBps),
            (quantize(jerkScore), config.smoothness.jerkComponentBps),
        ])
    }

    /// RMS of d(longitudinal)/dt in g/s over the vehicle-frame stream.
    private func longitudinalJerkRMS(_ frames: [VehicleFrameSample]) -> Double {
        var sumSquares = 0.0
        var count = 0
        for (a, b) in zip(frames, frames.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0, dt < 1 else { continue }
            let jerk = (b.longitudinal - a.longitudinal) / dt
            sumSquares += jerk * jerk
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sumSquares / Double(count)).squareRoot()
    }

    // MARK: - Control (spec §40)

    private func controlScore(
        events: [DrivingEvent],
        vehicleFrames: [VehicleFrameSample],
        metrics: inout [String: Double]
    ) -> Int {
        let brakingPeaks = events
            .filter { $0.kind == .braking || $0.kind == .hardBraking }
            .map(\.peakMagnitudeG)
        let corneringPeaks = events
            .filter { $0.kind == .cornering || $0.kind == .hardCornering }
            .map(\.peakMagnitudeG)

        let brakingStd = standardDeviation(brakingPeaks)
        let corneringStd = standardDeviation(corneringPeaks)
        metrics["controlBrakingPeakStd"] = brakingStd
        metrics["controlCorneringPeakStd"] = corneringStd

        let oscillation = oscillationRatePerMinute(vehicleFrames)
        metrics["controlOscillationPerMinute"] = oscillation

        return combine([
            (quantize(config.control.brakingConsistencyCurve.value(at: brakingStd)),
             config.control.brakingComponentBps),
            (quantize(config.control.corneringConsistencyCurve.value(at: corneringStd)),
             config.control.corneringComponentBps),
            (quantize(config.control.oscillationRateCurve.value(at: oscillation)),
             config.control.oscillationComponentBps),
        ])
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Longitudinal sign flips per minute where |value| clears the deadband
    /// on both sides — throttle/brake pumping.
    private func oscillationRatePerMinute(_ frames: [VehicleFrameSample]) -> Double {
        guard let first = frames.first, let last = frames.last,
              last.timestamp > first.timestamp else { return 0 }
        let deadband = config.control.oscillationDeadbandG
        var flips = 0
        var lastSign = 0
        for frame in frames where abs(frame.longitudinal) > deadband {
            let sign = frame.longitudinal > 0 ? 1 : -1
            if lastSign != 0 && sign != lastSign {
                flips += 1
            }
            lastSign = sign
        }
        let minutes = (last.timestamp - first.timestamp) / 60
        return Double(flips) / minutes
    }

    // MARK: - Compliance (spec §41)

    private func complianceScore(
        trajectory: ProcessedTrajectory,
        speedLimits: [SpeedLimitSegment],
        metrics: inout [String: Double]
    ) -> (bps: Int, hasData: Bool) {
        let limits = speedLimits.filter { $0.limitMps != nil }
        guard !limits.isEmpty, trajectory.totalDistanceMeters > 0 else {
            return (config.compliance.noDataBps, false)
        }

        // Distance-weighted relative overspeed beyond the grace margin.
        var exceedanceSum = 0.0
        var coveredMeters = 0.0
        for (a, b) in zip(trajectory.points, trajectory.points.dropFirst()) {
            let stepMeters = b.distanceAlongPathMeters - a.distanceAlongPathMeters
            guard stepMeters > 0 else { continue }
            guard let limit = limit(at: a.distanceAlongPathMeters, in: limits) else { continue }
            coveredMeters += stepMeters
            let over = a.speedMps - limit - config.compliance.graceMps
            if over > 0 {
                exceedanceSum += stepMeters * (over / limit)
            }
        }
        guard coveredMeters > 0 else {
            return (config.compliance.noDataBps, false)
        }
        let index = exceedanceSum / coveredMeters
        metrics["complianceExceedanceIndex"] = index
        return (quantize(config.compliance.exceedanceCurve.value(at: index)), true)
    }

    private func limit(at meters: Double, in segments: [SpeedLimitSegment]) -> Double? {
        for segment in segments
        where meters >= segment.startDistanceMeters && meters < segment.endDistanceMeters {
            return segment.limitMps
        }
        return nil
    }

    // MARK: - Quantization & combination (the determinism contract)

    /// Curve output (Double bps) → integer bps, half-up rounding, clamped.
    /// TS mirror: `Math.min(10000, Math.max(0, Math.round(x)))`.
    private func quantize(_ bps: Double) -> Int {
        min(10_000, max(0, Int(bps.rounded())))
    }

    /// Integer-weighted combination with truncating division.
    /// TS mirror: `Math.trunc(sum / 10000)`.
    private func combine(_ parts: [(score: Int, weightBps: Int)]) -> Int {
        var weighted = 0
        for part in parts {
            weighted += part.score * part.weightBps
        }
        return weighted / 10_000
    }
}

// MARK: - Config loading

extension ScoringConfig {
    /// Decodes and validates a config JSON (the canonical file lives at
    /// `configs/scoring/v1.json`). Throws on structural invalidity — a bad
    /// config must never score runs.
    public static func load(from data: Data) throws -> ScoringConfig {
        let config = try JSONDecoder().decode(ScoringConfig.self, from: data)
        guard config.isValid else {
            throw ScoringConfigError.invalidConfig
        }
        return config
    }
}

public enum ScoringConfigError: Error, Equatable {
    case invalidConfig
}
