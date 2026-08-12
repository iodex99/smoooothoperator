import Foundation
import Testing
import SOCore
import SOModels
import SOTelemetry
@testable import SOIntegrity

@Suite("RunIntegrityEngine units")
struct RunIntegrityEngineTests {
    let engine = RunIntegrityEngine()
    let origin = GeoCoordinate(latitude: 34.0259, longitude: -118.7798)
    let base = 1_754_982_000.0

    /// Honest-looking fixes: 1 Hz, constant speed, jittered clock and
    /// accuracy, positions consistent with the reported speed.
    private func honestFixes(count: Int, speedMps: Double = 20) -> [GPSSample] {
        var rng = SeededRandomNumberGenerator(seed: 1)
        return (0..<count).map { index in
            GPSSample(
                timestamp: base + Double(index) + Double.random(in: -0.01...0.01, using: &rng),
                coordinate: origin.destination(bearingDegrees: 0, distanceMeters: speedMps * Double(index)),
                altitude: 50,
                horizontalAccuracy: 5 + Double.random(in: -1...1, using: &rng),
                course: 0,
                speed: speedMps + Double.random(in: -0.2...0.2, using: &rng)
            )
        }
    }

    private func emptyTrajectory() -> ProcessedTrajectory {
        ProcessedTrajectory(points: [], gaps: [], rejectedSampleCount: 0)
    }

    private func evaluate(
        gps: [GPSSample],
        imu: [IMUSample] = [],
        trajectory: ProcessedTrajectory? = nil,
        confidence: Int? = nil,
        adherence: RouteAdherence? = nil
    ) -> IntegrityReport {
        engine.evaluate(
            rawGPS: gps,
            rawIMU: imu,
            trajectory: trajectory ?? emptyTrajectory(),
            locationConfidence: confidence,
            routeAdherence: adherence
        )
    }

    @Test("honest data with no signals verifies")
    func honestVerifies() {
        let report = evaluate(gps: honestFixes(count: 120), confidence: 95)
        #expect(report.verdict == .verified)
        #expect(report.findings.isEmpty)
    }

    @Test("timestamp regressions are critical")
    func timestampRegression() {
        var fixes = honestFixes(count: 60)
        fixes[30].timestamp = fixes[29].timestamp - 0.5
        let report = evaluate(gps: fixes)
        #expect(report.verdict == .invalid)
        #expect(report.findings.contains { $0.flag == .timestampAnomaly && $0.severity == .critical })
    }

    @Test("impossible reported speed is critical")
    func impossibleReportedSpeed() {
        var fixes = honestFixes(count: 60)
        fixes[20].speed = 150
        let report = evaluate(gps: fixes)
        #expect(report.verdict == .invalid)
        #expect(report.findings.contains { $0.flag == .impossibleSpeed })
    }

    @Test("sustained impossible implied movement is critical; a lone GPS jump is not")
    func impossibleImpliedSpeed() {
        // Growing offset: 400 m/s of sustained "travel" across 4 pairs.
        var sustained = honestFixes(count: 60)
        for (step, index) in (20...23).enumerated() {
            sustained[index].coordinate = sustained[index].coordinate
                .destination(bearingDegrees: 90, distanceMeters: Double(step + 1) * 400)
        }
        let sustainedReport = evaluate(gps: sustained)
        #expect(sustainedReport.verdict == .invalid)
        #expect(sustainedReport.findings.contains { $0.flag == .impossibleSpeed })

        // A single displaced fix (multipath jump) implies impossible speed
        // in and out — honest data, never a cheating accusation.
        var lonely = honestFixes(count: 60)
        lonely[20].coordinate = lonely[20].coordinate.destination(bearingDegrees: 90, distanceMeters: 400)
        let lonelyReport = evaluate(gps: lonely)
        #expect(!lonelyReport.findings.contains { $0.flag == .impossibleSpeed })
    }

    @Test("sustained impossible acceleration is critical; a single noisy pair is not")
    func impossibleAcceleration() {
        var sustained = honestFixes(count: 60)
        sustained[20].speed = 10
        sustained[21].speed = 30   // +20 m/s²
        sustained[22].speed = 50   // +20 m/s² again → sustained
        // Keep positions loosely consistent so the ratio check stays quiet.
        let sustainedReport = evaluate(gps: sustained)
        #expect(sustainedReport.findings.contains { $0.flag == .impossibleAcceleration })
        #expect(sustainedReport.verdict == .invalid)

        // A lone bad pair (only possible at the stream end — any mid-run
        // spike creates a second pair on the way down) must not accuse.
        var single = honestFixes(count: 60)
        single[59].speed = 40
        let singleReport = evaluate(gps: single)
        #expect(!singleReport.findings.contains { $0.flag == .impossibleAcceleration })
    }

    @Test("a compressed clock shifts implied/reported speed ratio — critical")
    func speedRatioMismatch() {
        // Positions imply 20 m/s over each 1s gap, but the receiver claims 10.
        var fixes = honestFixes(count: 80, speedMps: 20)
        for index in fixes.indices {
            fixes[index].speed = 10
        }
        let report = evaluate(gps: fixes)
        #expect(report.verdict == .invalid)
        #expect(report.findings.contains { $0.flag == .timestampAnomaly && $0.severity == .critical })
    }

    @Test("two mock signatures together are critical; one alone is a warning")
    func mockSignatures() {
        // Metronome clock + zero accuracy variance.
        var scripted = honestFixes(count: 120)
        for index in scripted.indices {
            scripted[index].timestamp = base + Double(index)  // perfect clock
            scripted[index].horizontalAccuracy = 5            // zero variance
        }
        let critical = evaluate(gps: scripted)
        #expect(critical.verdict == .invalid)
        #expect(critical.findings.contains { $0.flag == .mockLocation && $0.severity == .critical })

        // Only zero variance; clock stays jittered.
        var oneSignature = honestFixes(count: 120)
        for index in oneSignature.indices {
            oneSignature[index].horizontalAccuracy = 5
        }
        let warning = evaluate(gps: oneSignature)
        #expect(warning.verdict == .questionable)
        #expect(warning.findings.contains { $0.flag == .mockLocation && $0.severity == .warning })
    }

    @Test("dead IMU while GPS moves counts as a mock signature")
    func deadIMU() {
        var fixes = honestFixes(count: 120)
        for index in fixes.indices {
            fixes[index].horizontalAccuracy = 5  // one signature already
        }
        // 1200 IMU samples of pure gravity while GPS claims 20 m/s.
        let imu = (0..<1200).map { index in
            IMUSample(timestamp: base + Double(index) * 0.1,
                      accelX: 0, accelY: 0, accelZ: -1,
                      gyroX: 0, gyroY: 0, gyroZ: 0)
        }
        let report = evaluate(gps: fixes, imu: imu)
        #expect(report.verdict == .invalid)
        #expect(report.findings.contains { $0.flag == .mockLocation && $0.severity == .critical })
    }

    @Test("long gaps and heavy rejection are warnings → questionable")
    func gapsAndRejection() {
        let gappy = ProcessedTrajectory(
            points: [],
            gaps: [TelemetryGap(startTime: base, endTime: base + 12, reason: .noSamples)],
            rejectedSampleCount: 0
        )
        let gapReport = evaluate(gps: honestFixes(count: 60), trajectory: gappy)
        #expect(gapReport.verdict == .questionable)
        #expect(gapReport.findings.contains { $0.flag == .suspiciousGap })

        let rejected = ProcessedTrajectory(
            points: (0..<90).map {
                TrajectoryPoint(timestamp: base + Double($0), coordinate: origin, speedMps: 20,
                                headingDegrees: 0, distanceAlongPathMeters: 0, horizontalAccuracy: 5)
            },
            gaps: [],
            rejectedSampleCount: 10
        )
        let rejectionReport = evaluate(gps: honestFixes(count: 60), trajectory: rejected)
        #expect(rejectionReport.verdict == .questionable)
        #expect(rejectionReport.findings.contains { $0.flag == .gpsJump })
    }

    @Test("missed gates and course deviation are critical route skips")
    func routeAdherenceFindings() {
        let missedGates = evaluate(
            gps: honestFixes(count: 60),
            adherence: RouteAdherence(expectedGates: 4, gatesHit: 2, deviationDetected: false)
        )
        #expect(missedGates.verdict == .invalid)
        #expect(missedGates.findings.contains { $0.flag == .routeSkip })

        let deviated = evaluate(
            gps: honestFixes(count: 60),
            adherence: RouteAdherence(expectedGates: 4, gatesHit: 4, deviationDetected: true)
        )
        #expect(deviated.verdict == .invalid)
    }

    @Test("poor location confidence alone demotes to questionable, never invalid")
    func lowConfidence() {
        let report = evaluate(gps: honestFixes(count: 120), confidence: 42)
        #expect(report.verdict == .questionable)
        #expect(!report.findings.contains { $0.severity == .critical })
    }

    @Test("empty inputs verify vacuously — no data is not evidence of cheating")
    func emptyInputs() {
        let report = evaluate(gps: [])
        #expect(report.verdict == .verified)
    }
}
