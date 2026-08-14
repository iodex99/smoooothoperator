import Foundation
import SOCore
import SOTelemetry
import Testing
@testable import SOIntegrity

/// The largest fairness gap in the product: pace is 35% of the score and is
/// measured between two gates on a public road, so a driver who catches
/// three red lights was compared against one who caught none as though they
/// had driven the same road.
///
/// The rule is the same one the flying start gets — kept, scored, shown,
/// ranked nowhere — because being stuck in traffic is not cheating and must
/// never be labelled as though it were.
@Suite("Traffic and stopped time")
struct InterruptionTests {
    /// Builds a trajectory that drives, optionally stops, then drives again.
    static func trajectory(
        movingSeconds: Double,
        stoppedSeconds: Double,
        speedMps: Double = 20
    ) -> ProcessedTrajectory {
        var points: [TrajectoryPoint] = []
        var t = 0.0
        var lat = 34.0
        func append(speed: Double) {
            points.append(TrajectoryPoint(
                timestamp: t,
                coordinate: GeoCoordinate(latitude: lat, longitude: -118.0),
                speedMps: speed,
                headingDegrees: 90,
                distanceAlongPathMeters: 0,
                horizontalAccuracy: 5
            ))
        }
        // First half of the driving.
        while t < movingSeconds / 2 {
            append(speed: speedMps)
            lat += 0.00018
            t += 0.1
        }
        // The interruption.
        let stopUntil = t + stoppedSeconds
        while t < stopUntil {
            append(speed: 0)
            t += 0.1
        }
        // The rest of the driving.
        let driveUntil = t + movingSeconds / 2
        while t < driveUntil {
            append(speed: speedMps)
            lat += 0.00018
            t += 0.1
        }
        return ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0)
    }

    static let config = IntegrityConfig.default

    static func engine() -> RunIntegrityEngine {
        RunIntegrityEngine(config: config)
    }

    static func report(_ trajectory: ProcessedTrajectory) -> IntegrityReport {
        engine().evaluate(
            rawGPS: [],
            rawIMU: [],
            trajectory: trajectory,
            locationConfidence: nil,
            routeAdherence: nil
        )
    }

    @Test("stopped time is measured, not guessed")
    func measuresStoppedTime() {
        let trajectory = Self.trajectory(movingSeconds: 100, stoppedSeconds: 40)
        let stopped = RunIntegrityEngine.stoppedSeconds(
            trajectory: trajectory, stoppedSpeedMps: Self.config.stoppedSpeedMps
        )
        #expect(abs(stopped - 40) < 1, "measured \(stopped)s of stopping, expected ~40")
    }

    @Test("an uninterrupted run is not flagged")
    func cleanRunIsClean() {
        let report = Self.report(Self.trajectory(movingSeconds: 200, stoppedSeconds: 0))
        #expect(!report.findings.contains { $0.flag == .heavilyInterrupted })
    }

    @Test("a run stopped for most of its length cannot be ranked")
    func heavilyInterruptedIsNotRanked() {
        // 100 s driving, 90 s stopped — 47% of the run.
        let report = Self.report(Self.trajectory(movingSeconds: 100, stoppedSeconds: 90))
        let finding = report.findings.first { $0.flag == .heavilyInterrupted }
        #expect(finding != nil, "a run stopped for half its length is not comparable")
        #expect(finding?.severity == .warning, "traffic is not cheating")
        #expect(
            report.verdict == .questionable,
            "kept and scored, but never ranked — got \(report.verdict)"
        )
    }

    @Test("one junction never gets a driver flagged")
    func singleJunctionIsFine() {
        // The absolute floor exists for exactly this: on a short course a
        // single red light can exceed the fraction while being ordinary
        // driving, and a label here would teach drivers to run lights.
        let report = Self.report(Self.trajectory(movingSeconds: 40, stoppedSeconds: 15))
        #expect(
            !report.findings.contains { $0.flag == .heavilyInterrupted },
            "15 s at one junction is normal driving"
        )
    }

    @Test("the evidence carries the numbers a driver can check")
    func evidenceIsSpecific() {
        let report = Self.report(Self.trajectory(movingSeconds: 100, stoppedSeconds: 90))
        let detail = report.findings.first { $0.flag == .heavilyInterrupted }?.detail
        // Byte-identical to the TypeScript port — golden vectors compare it.
        #expect(detail == "stopped for 90 s of 190 s (47% of the run)", "got \(detail ?? "nil")")
    }

    @Test("a lost signal is not a red light")
    func gapsAreNotStops() {
        // A run with a 60 s hole in it has zero recorded speed, but that is
        // suspiciousGap's job to judge. Counting it as stopping would flag
        // every drive through a tunnel.
        var points: [TrajectoryPoint] = []
        for step in 0..<100 {
            points.append(TrajectoryPoint(
                timestamp: Double(step) * 0.1,
                coordinate: GeoCoordinate(latitude: 34.0 + Double(step) * 0.00018, longitude: -118.0),
                speedMps: 20, headingDegrees: 90,
                distanceAlongPathMeters: 0, horizontalAccuracy: 5
            ))
        }
        // 60-second hole, then driving resumes.
        for step in 0..<100 {
            points.append(TrajectoryPoint(
                timestamp: 70 + Double(step) * 0.1,
                coordinate: GeoCoordinate(latitude: 34.02 + Double(step) * 0.00018, longitude: -118.0),
                speedMps: 20, headingDegrees: 90,
                distanceAlongPathMeters: 0, horizontalAccuracy: 5
            ))
        }
        let stopped = RunIntegrityEngine.stoppedSeconds(
            trajectory: ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0),
            stoppedSpeedMps: Self.config.stoppedSpeedMps
        )
        #expect(stopped == 0, "a gap counted as \(stopped)s of stopping")
    }

    @Test("a car braking to a stop is not counted as stopped yet")
    func brakingIsNotStopped() {
        // Only intervals where BOTH ends are below the threshold count, so
        // the deceleration into a stop is driving, not queueing.
        let points = [
            TrajectoryPoint(timestamp: 0, coordinate: GeoCoordinate(latitude: 34, longitude: -118),
                            speedMps: 10, headingDegrees: 90,
                            distanceAlongPathMeters: 0, horizontalAccuracy: 5),
            TrajectoryPoint(timestamp: 1, coordinate: GeoCoordinate(latitude: 34, longitude: -118),
                            speedMps: 0, headingDegrees: 90,
                            distanceAlongPathMeters: 0, horizontalAccuracy: 5),
            TrajectoryPoint(timestamp: 2, coordinate: GeoCoordinate(latitude: 34, longitude: -118),
                            speedMps: 0, headingDegrees: 90,
                            distanceAlongPathMeters: 0, horizontalAccuracy: 5),
        ]
        let stopped = RunIntegrityEngine.stoppedSeconds(
            trajectory: ProcessedTrajectory(points: points, gaps: [], rejectedSampleCount: 0),
            stoppedSpeedMps: Self.config.stoppedSpeedMps
        )
        #expect(stopped == 1, "only the stopped second counts, got \(stopped)")
    }

    @Test("the thresholds are configuration, not magic numbers")
    func configurable() {
        #expect(Self.config.stoppedSpeedMps == 0.5)
        #expect(Self.config.maxStoppedFraction == 0.25)
        #expect(Self.config.minStoppedSecondsToFlag == 20)
    }
}
