import Foundation
import SOCore
import SOModels
import SOTelemetry

/// Thresholds for run integrity evaluation (spec §45). Configurable — cheat
/// thresholds are tuned server-side, never baked into logic. The same rules
/// are ported to TypeScript for the authoritative server pass and held
/// equivalent by the cheat-profile golden vectors.
public struct IntegrityConfig: Codable, Sendable, Equatable {
    /// Ground speed above this is cheat-grade impossible, m/s (~200 mph).
    /// Speed permitted when crossing the START gate, m/s. Pace is the
    /// largest slice of the score, so a driver who arrives at the line at
    /// 100 km/h banks an advantage no amount of skill can answer. Runs above
    /// this are kept and scored but never ranked (a warning, not an
    /// accusation — most flying starts are honest mistakes).
    ///
    /// 8 m/s ≈ 29 km/h: a slow roll-up, achievable where stopping is not.
    public var maxStartEntrySpeedMps: Double

    /// Below this the car is treated as stopped, m/s. Not zero: a stationary
    /// car still reports drift.
    public var stoppedSpeedMps: Double
    /// A run may be interrupted for this fraction of its duration before its
    /// pace stops being comparable.
    public var maxStoppedFraction: Double
    /// …but never flag less than this many seconds of stopping. One junction
    /// on a short course can exceed the fraction while being completely
    /// normal driving, and an accusation-shaped label for a single red light
    /// would train drivers to run them.
    public var minStoppedSecondsToFlag: Double

    public var maxPlausibleSpeedMps: Double
    /// Consecutive fix pairs whose *implied* speed must exceed the limit
    /// before it counts as cheating — isolated impossible pairs are honest
    /// GPS jumps (multipath), already handled by trajectory rejection.
    public var minImpossibleSpeedPairs: Int
    /// |dv/dt| of *reported* speeds above this is impossible for a road
    /// vehicle, m/s² — must hold across `minImpossibleAccelPairs` pairs so
    /// single-fix noise can't accuse anyone.
    public var maxPlausibleAccelMps2: Double
    public var minImpossibleAccelPairs: Int
    /// Moving segments where median(implied speed / reported speed) leaves
    /// this band indicate a manipulated clock.
    public var speedRatioBand: ClosedRange<Double>
    /// Minimum moving fixes before the speed-ratio check may fire.
    public var minRatioSamples: Int
    /// Reported-accuracy variance below this across a whole run is a
    /// scripted-fix signature, m².
    public var minAccuracyVariance: Double
    /// GPS fix clock jitter below this is a metronome (mock) clock, seconds.
    public var minClockJitterSeconds: Double
    /// Max |accel norm − 1 g| below this while GPS claims motion = the phone
    /// never felt the drive, g.
    public var deadIMUDynamicsG: Double
    /// Acceptable band for p95(|gyro|) / p95(GPS heading rate). Honest
    /// sensors track the turns GPS sees (≈1); scaled or injected IMU
    /// leaves the band.
    public var gyroHeadingRatioBand: ClosedRange<Double>
    /// Minimum p95 GPS heading rate before the gyro check may fire, rad/s —
    /// a straight-line run can't assess gyro consistency.
    public var minHeadingRateRadPerSec: Double
    /// GPS speed above which the IMU checks apply, m/s.
    public var imuCheckSpeedMps: Double
    /// A single trajectory gap longer than this is suspicious, seconds.
    public var suspiciousGapSeconds: Double
    /// Rejected-sample fraction above this indicates jump-ridden data.
    public var maxRejectedFraction: Double
    /// Location confidence below this can never verify (spec §21: <50 poor).
    public var minLocationConfidence: Int

    public init(
        maxStartEntrySpeedMps: Double = 8,
        stoppedSpeedMps: Double = 0.5,
        maxStoppedFraction: Double = 0.25,
        minStoppedSecondsToFlag: Double = 20,
        maxPlausibleSpeedMps: Double,
        minImpossibleSpeedPairs: Int,
        maxPlausibleAccelMps2: Double,
        minImpossibleAccelPairs: Int,
        speedRatioBand: ClosedRange<Double>,
        minRatioSamples: Int,
        minAccuracyVariance: Double,
        minClockJitterSeconds: Double,
        deadIMUDynamicsG: Double,
        gyroHeadingRatioBand: ClosedRange<Double>,
        minHeadingRateRadPerSec: Double,
        imuCheckSpeedMps: Double,
        suspiciousGapSeconds: Double,
        maxRejectedFraction: Double,
        minLocationConfidence: Int
    ) {
        self.maxStartEntrySpeedMps = maxStartEntrySpeedMps
        self.stoppedSpeedMps = stoppedSpeedMps
        self.maxStoppedFraction = maxStoppedFraction
        self.minStoppedSecondsToFlag = minStoppedSecondsToFlag
        self.maxPlausibleSpeedMps = maxPlausibleSpeedMps
        self.minImpossibleSpeedPairs = minImpossibleSpeedPairs
        self.maxPlausibleAccelMps2 = maxPlausibleAccelMps2
        self.minImpossibleAccelPairs = minImpossibleAccelPairs
        self.speedRatioBand = speedRatioBand
        self.minRatioSamples = minRatioSamples
        self.minAccuracyVariance = minAccuracyVariance
        self.minClockJitterSeconds = minClockJitterSeconds
        self.deadIMUDynamicsG = deadIMUDynamicsG
        self.gyroHeadingRatioBand = gyroHeadingRatioBand
        self.minHeadingRateRadPerSec = minHeadingRateRadPerSec
        self.imuCheckSpeedMps = imuCheckSpeedMps
        self.suspiciousGapSeconds = suspiciousGapSeconds
        self.maxRejectedFraction = maxRejectedFraction
        self.minLocationConfidence = minLocationConfidence
    }

    public static let `default` = IntegrityConfig(
        maxStartEntrySpeedMps: 8,
        maxPlausibleSpeedMps: 90,
        minImpossibleSpeedPairs: 3,
        maxPlausibleAccelMps2: 12,
        minImpossibleAccelPairs: 2,
        speedRatioBand: 0.7...1.3,
        minRatioSamples: 50,
        minAccuracyVariance: 1e-6,
        minClockJitterSeconds: 1e-4,
        deadIMUDynamicsG: 0.01,
        gyroHeadingRatioBand: 0.4...1.8,
        minHeadingRateRadPerSec: 0.05,
        imuCheckSpeedMps: 5,
        suspiciousGapSeconds: 4,
        maxRejectedFraction: 0.01,
        minLocationConfidence: 50
    )
}

/// How badly a finding taints the run.
public enum IntegritySeverity: String, Codable, Sendable {
    /// Data quality problem: the run cannot rank, nobody is accused.
    case warning
    /// Clear violation or physically impossible data: the run is invalid.
    case critical
}

/// One integrity signal with its evidence.
public struct IntegrityFinding: Codable, Sendable, Equatable {
    public var flag: IntegrityFlag
    public var severity: IntegritySeverity
    /// Human-readable evidence — shown to ops, never used in logic.
    public var detail: String

    public init(flag: IntegrityFlag, severity: IntegritySeverity, detail: String) {
        self.flag = flag
        self.severity = severity
        self.detail = detail
    }
}

/// Course-adherence summary handed in by the caller (mapped from
/// `CourseProgressTracker`) — keeps SOIntegrity decoupled from SOCourse.
public struct RouteAdherence: Codable, Sendable, Equatable {
    public var expectedGates: Int
    public var gatesHit: Int
    public var deviationDetected: Bool

    public init(expectedGates: Int, gatesHit: Int, deviationDetected: Bool) {
        self.expectedGates = expectedGates
        self.gatesHit = gatesHit
        self.deviationDetected = deviationDetected
    }
}

/// The engine's output: findings + the verdict they imply.
public struct IntegrityReport: Codable, Sendable, Equatable {
    public var findings: [IntegrityFinding]
    public var verdict: RunVerificationStatus

    public init(findings: [IntegrityFinding], verdict: RunVerificationStatus) {
        self.findings = findings
        self.verdict = verdict
    }
}

/// Evaluates a completed run for cheating and data-quality problems
/// (spec §45). Client-side the result is provisional; the server re-runs the
/// same checks on the uploaded raw telemetry and its verdict is the only one
/// that counts (spec §46).
///
/// Principles: physically impossible data or clear manipulation → `invalid`;
/// honest-but-degraded data → `questionable` (ranks nowhere, accuses no
/// one); uncertainty NEVER accuses (spec §44).
public struct RunIntegrityEngine: Sendable {
    public let config: IntegrityConfig

    public init(config: IntegrityConfig = .default) {
        self.config = config
    }

    public func evaluate(
        rawGPS: [GPSSample],
        rawIMU: [IMUSample],
        trajectory: ProcessedTrajectory,
        locationConfidence: Int?,
        routeAdherence: RouteAdherence?,
        /// Speed as the driver crossed the START gate, m/s. nil when the
        /// crossing is unknown (no gate hit), which is not a finding —
        /// a run that never started is caught elsewhere.
        startEntrySpeedMps: Double? = nil
    ) -> IntegrityReport {
        var findings: [IntegrityFinding] = []

        findings += startLineFindings(entrySpeedMps: startEntrySpeedMps)
        findings += interruptionFindings(trajectory: trajectory)

        findings += timestampFindings(rawGPS: rawGPS)
        findings += impossiblePhysicsFindings(rawGPS: rawGPS)
        findings += speedRatioFindings(rawGPS: rawGPS)

        let mockSignatures = mockSignatureFindings(rawGPS: rawGPS, rawIMU: rawIMU)
        findings += mockSignatures.findings

        findings += gapAndJumpFindings(trajectory: trajectory)
        findings += routeFindings(routeAdherence: routeAdherence)

        if let confidence = locationConfidence, confidence < config.minLocationConfidence {
            findings.append(IntegrityFinding(
                flag: .gpsJump,
                severity: .warning,
                detail: "location confidence \(confidence) below \(config.minLocationConfidence)"
            ))
        }

        let verdict: RunVerificationStatus =
            if findings.contains(where: { $0.severity == .critical }) {
                .invalid
            } else if !findings.isEmpty {
                .questionable
            } else {
                .verified
            }

        return IntegrityReport(findings: findings, verdict: verdict)
    }

    // MARK: - Checks

    private func timestampFindings(rawGPS: [GPSSample]) -> [IntegrityFinding] {
        var regressions = 0
        for (a, b) in zip(rawGPS, rawGPS.dropFirst()) where b.timestamp <= a.timestamp {
            regressions += 1
        }
        guard regressions > 0 else { return [] }
        return [IntegrityFinding(
            flag: .timestampAnomaly,
            severity: .critical,
            detail: "\(regressions) timestamp regression(s) in raw GPS"
        )]
    }

    private func impossiblePhysicsFindings(rawGPS: [GPSSample]) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []

        let impossibleReported = rawGPS.compactMap(\.speed).filter { $0 > config.maxPlausibleSpeedMps }

        // Implied speed must stay impossible across consecutive pairs —
        // isolated violations are honest multipath jumps (rejected by the
        // trajectory gate and surfaced via the rejection-rate warning).
        var impliedStreak = 0
        var sustainedImpliedRuns = 0
        for (a, b) in zip(rawGPS, rawGPS.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0 else { continue }
            if a.coordinate.distance(to: b.coordinate) / dt > config.maxPlausibleSpeedMps {
                impliedStreak += 1
                if impliedStreak == config.minImpossibleSpeedPairs {
                    sustainedImpliedRuns += 1
                }
            } else {
                impliedStreak = 0
            }
        }
        if !impossibleReported.isEmpty || sustainedImpliedRuns > 0 {
            findings.append(IntegrityFinding(
                flag: .impossibleSpeed,
                severity: .critical,
                detail: "reported>\(Int(config.maxPlausibleSpeedMps)): \(impossibleReported.count), sustained implied runs: \(sustainedImpliedRuns)"
            ))
        }

        // Reported-speed acceleration, sustained across consecutive pairs.
        var accelStreak = 0
        var impossibleAccelRuns = 0
        for index in 1..<max(rawGPS.count, 1) {
            guard let v0 = rawGPS[index - 1].speed, let v1 = rawGPS[index].speed else {
                accelStreak = 0
                continue
            }
            let dt = rawGPS[index].timestamp - rawGPS[index - 1].timestamp
            guard dt > 0 else { continue }
            if abs(v1 - v0) / dt > config.maxPlausibleAccelMps2 {
                accelStreak += 1
                if accelStreak == config.minImpossibleAccelPairs {
                    impossibleAccelRuns += 1
                }
            } else {
                accelStreak = 0
            }
        }
        if impossibleAccelRuns > 0 {
            findings.append(IntegrityFinding(
                flag: .impossibleAcceleration,
                severity: .critical,
                detail: "\(impossibleAccelRuns) sustained |dv/dt| run(s) above \(config.maxPlausibleAccelMps2) m/s²"
            ))
        }
        return findings
    }

    /// Implied-vs-reported speed: a compressed or stretched clock shifts the
    /// whole distribution, which no honest receiver does.
    private func speedRatioFindings(rawGPS: [GPSSample]) -> [IntegrityFinding] {
        var ratios: [Double] = []
        for (a, b) in zip(rawGPS, rawGPS.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0, let reported = b.speed, reported > 3 else { continue }
            let implied = a.coordinate.distance(to: b.coordinate) / dt
            ratios.append(implied / reported)
        }
        guard ratios.count >= config.minRatioSamples else { return [] }
        let median = ratios.sorted()[ratios.count / 2]
        guard !config.speedRatioBand.contains(median) else { return [] }
        return [IntegrityFinding(
            flag: .timestampAnomaly,
            severity: .critical,
            detail: "median implied/reported speed ratio \(String(format: "%.2f", median)) outside \(config.speedRatioBand)"
        )]
    }

    /// Start-line fairness. Pace is 35% of the score and is measured from
    /// the start gate, so entry speed is worth free seconds no skill can
    /// recover. This does not accuse anyone: the run is scored and shown,
    /// it simply cannot rank beside runs that launched from the line.
    /// How long the car spent stopped, in seconds.
    ///
    /// Deliberately part of the determinism contract rather than a UI
    /// convenience: it decides a verdict, so both implementations must agree
    /// on it exactly. Gaps are not counted — a lost signal is not a red
    /// light, and `suspiciousGap` already judges those.
    public static func stoppedSeconds(
        trajectory: ProcessedTrajectory,
        stoppedSpeedMps: Double,
        maxGapSeconds: Double = 3
    ) -> Double {
        var total = 0.0
        for (a, b) in zip(trajectory.points, trajectory.points.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0, dt <= maxGapSeconds else { continue }
            // Both ends slow: a car braking to a stop is not yet stopped.
            if a.speedMps < stoppedSpeedMps && b.speedMps < stoppedSpeedMps {
                total += dt
            }
        }
        return total
    }

    private func interruptionFindings(trajectory: ProcessedTrajectory) -> [IntegrityFinding] {
        let duration = trajectory.duration
        guard duration > 0 else { return [] }
        let stopped = Self.stoppedSeconds(
            trajectory: trajectory,
            stoppedSpeedMps: config.stoppedSpeedMps
        )
        guard stopped >= config.minStoppedSecondsToFlag else { return [] }
        let fraction = stopped / duration
        guard fraction > config.maxStoppedFraction else { return [] }
        return [IntegrityFinding(
            flag: .heavilyInterrupted,
            severity: .warning,
            detail: String(
                format: "stopped for %.0f s of %.0f s (%.0f%% of the run)",
                stopped, duration, fraction * 100
            )
        )]
    }

    private func startLineFindings(entrySpeedMps: Double?) -> [IntegrityFinding] {
        guard let entrySpeedMps, entrySpeedMps.isFinite else { return [] }
        guard entrySpeedMps > config.maxStartEntrySpeedMps else { return [] }
        return [IntegrityFinding(
            flag: .flyingStart,
            severity: .warning,
            detail: String(
                format: "crossed the start line at %.1f m/s (limit %.1f)",
                entrySpeedMps, config.maxStartEntrySpeedMps
            )
        )]
    }

    /// Mock-location signatures. Each alone is circumstantial (warning);
    /// two or more together are a scripted feed (critical).
    private func mockSignatureFindings(
        rawGPS: [GPSSample],
        rawIMU: [IMUSample]
    ) -> (findings: [IntegrityFinding], signatureCount: Int) {
        guard rawGPS.count >= 50 else { return ([], 0) }
        var signatures: [String] = []

        let accuracies = rawGPS.map(\.horizontalAccuracy)
        let meanAccuracy = accuracies.reduce(0, +) / Double(accuracies.count)
        let accuracyVariance = accuracies.reduce(0) { $0 + ($1 - meanAccuracy) * ($1 - meanAccuracy) }
            / Double(accuracies.count)
        if accuracyVariance < config.minAccuracyVariance {
            signatures.append("zero accuracy variance")
        }

        let dts = zip(rawGPS, rawGPS.dropFirst()).map { $1.timestamp - $0.timestamp }.filter { $0 > 0 }
        if dts.count > 10 {
            let meanDt = dts.reduce(0, +) / Double(dts.count)
            let maxJitter = dts.map { abs($0 - meanDt) }.max() ?? 0
            if maxJitter < config.minClockJitterSeconds {
                signatures.append("metronome fix clock")
            }
        }

        // Dead IMU while GPS claims motion: the phone never felt the drive.
        var imuFindings: [IntegrityFinding] = []
        if let maxDeviation = movingIMUMaxDeviation(rawGPS: rawGPS, rawIMU: rawIMU) {
            if maxDeviation < config.deadIMUDynamicsG {
                signatures.append("dead IMU while moving")
            }
        }

        // Gyro must agree with the turn rate GPS course shows: scaled or
        // injected sensors leave the consistency band.
        if let ratio = gyroHeadingRatio(rawGPS: rawGPS, rawIMU: rawIMU),
           !config.gyroHeadingRatioBand.contains(ratio) {
            imuFindings.append(IntegrityFinding(
                flag: .sensorMismatch,
                severity: .warning,
                detail: "p95 gyro / p95 GPS heading rate = \(String(format: "%.2f", ratio)) outside \(config.gyroHeadingRatioBand)"
            ))
        }

        var findings = imuFindings
        if signatures.count >= 2 {
            findings.append(IntegrityFinding(
                flag: .mockLocation,
                severity: .critical,
                detail: signatures.joined(separator: " + ")
            ))
        } else if signatures.count == 1 {
            findings.append(IntegrityFinding(
                flag: .mockLocation,
                severity: .warning,
                detail: signatures[0]
            ))
        }
        return (findings, signatures.count)
    }

    /// Max |accel norm − 1 g| over IMU samples taken while GPS speed exceeds
    /// the check threshold. Nil when there's no moving overlap.
    private func movingIMUMaxDeviation(
        rawGPS: [GPSSample],
        rawIMU: [IMUSample]
    ) -> Double? {
        guard !rawIMU.isEmpty, !rawGPS.isEmpty else { return nil }
        var deviations: [Double] = []
        var gpsIndex = 0
        for sample in rawIMU {
            while gpsIndex + 1 < rawGPS.count && rawGPS[gpsIndex + 1].timestamp <= sample.timestamp {
                gpsIndex += 1
            }
            guard let speed = rawGPS[gpsIndex].speed, speed > config.imuCheckSpeedMps else { continue }
            let norm = (sample.accelX * sample.accelX
                + sample.accelY * sample.accelY
                + sample.accelZ * sample.accelZ).squareRoot()
            deviations.append(abs(norm - 1))
        }
        guard deviations.count > 100 else { return nil }
        return deviations.max()
    }

    /// p95(|gyro|) over moving IMU samples divided by p95(|GPS heading
    /// rate|). Nil when the run has too little turning to assess.
    private func gyroHeadingRatio(rawGPS: [GPSSample], rawIMU: [IMUSample]) -> Double? {
        guard !rawIMU.isEmpty else { return nil }

        // Heading rate over ~1 s spans: receivers report course in steps, so
        // per-fix deltas are mostly zero with meaningless spikes.
        var headingRates: [Double] = []
        var later = 0
        for index in rawGPS.indices {
            while later < rawGPS.count && rawGPS[later].timestamp - rawGPS[index].timestamp < 1.0 {
                later += 1
            }
            guard later < rawGPS.count else { break }
            let a = rawGPS[index]
            let b = rawGPS[later]
            let dt = b.timestamp - a.timestamp
            guard dt > 0, let courseA = a.course, let courseB = b.course,
                  let speed = b.speed, speed > config.imuCheckSpeedMps
            else { continue }
            var delta = (courseB - courseA).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            headingRates.append(abs(delta * .pi / 180 / dt))
        }
        guard headingRates.count >= 20 else { return nil }
        let headingP95 = percentile95(headingRates)
        guard headingP95 > config.minHeadingRateRadPerSec else { return nil }

        var gyroNorms: [Double] = []
        var gpsIndex = 0
        for sample in rawIMU {
            while gpsIndex + 1 < rawGPS.count && rawGPS[gpsIndex + 1].timestamp <= sample.timestamp {
                gpsIndex += 1
            }
            guard let speed = rawGPS[gpsIndex].speed, speed > config.imuCheckSpeedMps else { continue }
            gyroNorms.append((sample.gyroX * sample.gyroX
                + sample.gyroY * sample.gyroY
                + sample.gyroZ * sample.gyroZ).squareRoot())
        }
        guard gyroNorms.count > 100 else { return nil }
        return percentile95(gyroNorms) / headingP95
    }

    private func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    private func gapAndJumpFindings(trajectory: ProcessedTrajectory) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []

        let longGaps = trajectory.gaps.filter { $0.duration > config.suspiciousGapSeconds }
        if !longGaps.isEmpty {
            findings.append(IntegrityFinding(
                flag: .suspiciousGap,
                severity: .warning,
                detail: "\(longGaps.count) gap(s) longer than \(Int(config.suspiciousGapSeconds))s"
            ))
        }

        let total = trajectory.points.count + trajectory.rejectedSampleCount
        if total > 0 {
            let rejectedFraction = Double(trajectory.rejectedSampleCount) / Double(total)
            if rejectedFraction > config.maxRejectedFraction {
                findings.append(IntegrityFinding(
                    flag: .gpsJump,
                    severity: .warning,
                    detail: "\(String(format: "%.1f", rejectedFraction * 100))% of raw fixes rejected by filtering"
                ))
            }
        }
        return findings
    }

    private func routeFindings(routeAdherence: RouteAdherence?) -> [IntegrityFinding] {
        guard let adherence = routeAdherence else { return [] }
        var findings: [IntegrityFinding] = []
        if adherence.gatesHit < adherence.expectedGates {
            findings.append(IntegrityFinding(
                flag: .routeSkip,
                severity: .critical,
                detail: "\(adherence.gatesHit)/\(adherence.expectedGates) checkpoints hit in order"
            ))
        }
        if adherence.deviationDetected {
            findings.append(IntegrityFinding(
                flag: .routeSkip,
                severity: .critical,
                detail: "run left the course corridor beyond the grace period"
            ))
        }
        return findings
    }
}
