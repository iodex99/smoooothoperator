import Foundation
import Testing
import SOCore
import SOCourse
import SOGhost
import SOIntegrity
import SOModels
import SOScoring
import SOSimulator
import SOTelemetry
@testable import SOSync

/// THROWAWAY ADVERSARIAL PROBES — delete before committing.
@Suite("ZZZ hostile input probes")
struct ZZZProbeTests {
    static let route = TelemetrySimulator.demoRoute(seed: 77)

    static let scoringConfig: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    static func gates(radius: Double = 40) -> [Checkpoint] {
        [0, route.count / 3, 2 * route.count / 3, route.count - 1]
            .enumerated().map { seq, i in
                Checkpoint(sequence: seq, center: route[i], radiusMeters: radius)
            }
    }

    static func gps(_ t: Double, _ lat: Double, _ lon: Double,
                    acc: Double = 5, speed: Double? = 10) -> GPSSample {
        GPSSample(timestamp: t, coordinate: GeoCoordinate(latitude: lat, longitude: lon),
                  horizontalAccuracy: acc, course: 90, speed: speed)
    }

    // MARK: - P1 NaN / infinite coordinates

    @Test("P1a: NaN coordinates through TrajectoryProcessor")
    func nanCoordinates() {
        let samples = [
            Self.gps(0, .nan, .nan),
            Self.gps(1, .nan, 0),
            Self.gps(2, 0, .nan),
            Self.gps(3, 34.03, -118.7),
        ]
        let traj = TrajectoryProcessor().process(samples)
        print("P1a kept=\(traj.points.count) rejected=\(traj.rejectedSampleCount) dist=\(traj.totalDistanceMeters) dur=\(traj.duration)")
        for p in traj.points {
            print("  P1a point t=\(p.timestamp) lat=\(p.coordinate.latitude) spd=\(p.speedMps) d=\(p.distanceAlongPathMeters) hdg=\(String(describing: p.headingDegrees))")
        }
        #expect(!traj.totalDistanceMeters.isNaN, "P1a FAIL: NaN leaked into totalDistanceMeters")
    }

    @Test("P1b: infinite coordinates through TrajectoryProcessor")
    func infiniteCoordinates() {
        let samples = [
            Self.gps(0, 34.03, -118.7),
            Self.gps(1, .infinity, .infinity),
            Self.gps(2, -.infinity, 0),
            Self.gps(3, 34.031, -118.7),
        ]
        let traj = TrajectoryProcessor().process(samples)
        print("P1b kept=\(traj.points.count) rejected=\(traj.rejectedSampleCount) dist=\(traj.totalDistanceMeters)")
        #expect(traj.totalDistanceMeters.isFinite, "P1b FAIL: non-finite distance")
    }

    @Test("P1c: NaN coordinate through CourseMatcher + tracker")
    func nanMatcher() {
        guard var tracker = CourseProgressTracker(polyline: Self.route, checkpoints: Self.gates()) else {
            Issue.record("tracker init failed"); return
        }
        let m = CourseMatcher(polyline: Self.route)!
        let nan = m.nearestMatch(to: GeoCoordinate(latitude: .nan, longitude: .nan))
        print("P1c nearestMatch NaN -> along=\(nan.distanceAlongCourseMeters) lateral=\(nan.lateralOffsetMeters) seg=\(nan.segmentIndex)")
        tracker.ingest(TrajectoryPoint(timestamp: 0, coordinate: GeoCoordinate(latitude: .nan, longitude: .nan),
                                       speedMps: 10, headingDegrees: nil,
                                       distanceAlongPathMeters: 0, horizontalAccuracy: 5))
        print("P1c after NaN ingest: progress=\(tracker.progressMeters) frac=\(tracker.progressFraction) off=\(tracker.isOffCourse) dev=\(tracker.deviationDetected)")
        #expect(!tracker.progressFraction.isNaN)
    }

    @Test("P1d: NaN in the POLYLINE itself")
    func nanPolyline() {
        let poly = [
            GeoCoordinate(latitude: 34.03, longitude: -118.7),
            GeoCoordinate(latitude: .nan, longitude: .nan),
            GeoCoordinate(latitude: 34.04, longitude: -118.7),
        ]
        let m = CourseMatcher(polyline: poly)
        print("P1d matcher from NaN polyline: \(m == nil ? "nil (rejected)" : "BUILT total=\(m!.totalDistanceMeters)")")
        let allNaN = CourseMatcher(polyline: [
            GeoCoordinate(latitude: .nan, longitude: .nan),
            GeoCoordinate(latitude: .nan, longitude: .nan),
        ])
        print("P1d all-NaN polyline: \(allNaN == nil ? "nil (rejected)" : "BUILT")")
        let v = CourseValidator().validate(polyline: poly, checkpoints: Self.gates())
        print("P1d CourseValidator on NaN polyline: \(v)")
    }

    @Test("P1e: full pipeline with NaN coordinates")
    func nanPipeline() {
        let run = TelemetrySimulator(profile: .normal, seed: 4).simulate(route: Self.route)
        var poisoned = run.gps
        for i in stride(from: 0, to: poisoned.count, by: 7) {
            poisoned[i].coordinate = GeoCoordinate(latitude: .nan, longitude: .nan)
        }
        let out = RunEvaluationPipeline.evaluate(
            gps: poisoned, imu: run.imu, route: Self.route, gates: Self.gates(),
            benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)
        if let out {
            print("P1e score=\(out.score.finalScore) verdict=\(out.integrity.verdict) gates=\(out.gatesHit) dev=\(out.deviationDetected) dist=\(out.trajectory.totalDistanceMeters) conf=\(out.confidence.score)")
            print("P1e breakdown pace=\(out.score.breakdown.paceBps) smooth=\(out.score.breakdown.smoothnessBps) ctrl=\(out.score.breakdown.controlBps) legal=\(out.score.breakdown.complianceBps)")
            #expect(out.score.finalScore >= 0 && out.score.finalScore <= 10_000, "P1e FAIL: score out of range")
        } else {
            print("P1e pipeline returned nil")
        }
    }

    // MARK: - P2 degenerate geometry

    @Test("P2: empty / single-point polylines, DriveSession init")
    func degenerateGeometry() {
        print("P2 matcher([]) = \(CourseMatcher(polyline: []) == nil ? "nil" : "BUILT")")
        print("P2 matcher([one]) = \(CourseMatcher(polyline: [Self.route[0]]) == nil ? "nil" : "BUILT")")
        let dup = [Self.route[0], Self.route[0], Self.route[0]]
        print("P2 matcher(3x same point) = \(CourseMatcher(polyline: dup) == nil ? "nil" : "BUILT")")
        let s1 = DriveSession(polyline: [], gates: [], benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)
        print("P2 DriveSession(empty polyline) = \(s1 == nil ? "nil (good)" : "BUILT (BAD)")")
        // Valid polyline but ZERO gates:
        let s2 = DriveSession(polyline: Self.route, gates: [], benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)
        print("P2 DriveSession(valid polyline, NO gates) = \(s2 == nil ? "nil" : "BUILT")")
        var t = CourseProgressTracker(polyline: Self.route, checkpoints: [])!
        t.ingest(TrajectoryPoint(timestamp: 0, coordinate: Self.route[0], speedMps: 10,
                                 headingDegrees: nil, distanceAlongPathMeters: 0, horizontalAccuracy: 5))
        print("P2 tracker with 0 checkpoints: hasFinished=\(t.hasFinished) next=\(String(describing: t.nextCheckpoint))")
    }

    @Test("P3: checkpoint radius 0 and gigantic")
    func checkpointRadii() {
        let zero = Checkpoint(sequence: 0, center: Self.route[0], radiusMeters: 0)
        print("P3 radius0 contains(center)=\(zero.contains(Self.route[0])) contains(1m off)=\(zero.contains(GeoCoordinate(latitude: Self.route[0].latitude + 0.00001, longitude: Self.route[0].longitude)))")
        let huge = Checkpoint(sequence: 0, center: Self.route[0], radiusMeters: 1e12)
        print("P3 radiusHuge contains(antipode)=\(huge.contains(GeoCoordinate(latitude: -34.03, longitude: 61.3)))")
        let neg = Checkpoint(sequence: 0, center: Self.route[0], radiusMeters: -50)
        print("P3 radiusNegative contains(center)=\(neg.contains(Self.route[0]))")
        let nanR = Checkpoint(sequence: 0, center: Self.route[0], radiusMeters: .nan)
        print("P3 radiusNaN contains(center)=\(nanR.contains(Self.route[0]))")

        // Huge radius on ALL gates: does one fix finish the whole course?
        let hugeGates = Self.gates(radius: 1e9)
        var tr = CourseProgressTracker(polyline: Self.route, checkpoints: hugeGates)!
        tr.ingest(TrajectoryPoint(timestamp: 0, coordinate: Self.route[0], speedMps: 10,
                                  headingDegrees: nil, distanceAlongPathMeters: 0, horizontalAccuracy: 5))
        print("P3 after ONE fix with 1e9m gates: hits=\(tr.checkpointHits.count) hasFinished=\(tr.hasFinished) progressFrac=\(tr.progressFraction)")
        #expect(!tr.hasFinished, "P3 FAIL: a single fix finished the whole course")

        // Validator's opinion:
        print("P3 CourseValidator(radius 0) = \(CourseValidator().validate(polyline: Self.route, checkpoints: Self.gates(radius: 0)))")
        print("P3 CourseValidator(radius 1e9) = \(CourseValidator().validate(polyline: Self.route, checkpoints: hugeGates))")
        print("P3 CourseValidator(radius -50) = \(CourseValidator().validate(polyline: Self.route, checkpoints: Self.gates(radius: -50)))")
    }

    // MARK: - P4 timestamps

    @Test("P4a: identical timestamps everywhere")
    func identicalTimestamps() {
        let samples = (0..<50).map { i in
            Self.gps(1000, 34.03 + Double(i) * 0.0001, -118.7)
        }
        let traj = TrajectoryProcessor().process(samples)
        print("P4a identical ts: kept=\(traj.points.count) rejected=\(traj.rejectedSampleCount) dur=\(traj.duration) dist=\(traj.totalDistanceMeters)")
        let out = RunEvaluationPipeline.evaluate(gps: samples, imu: [], route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        print("P4a pipeline: score=\(out?.score.finalScore ?? -1) verdict=\(String(describing: out?.integrity.verdict)) pace=\(out?.score.breakdown.paceBps ?? -1)")
    }

    @Test("P4b: timestamps strictly decreasing")
    func backwardsTimestamps() {
        let samples = (0..<50).map { i in
            Self.gps(1000 - Double(i), 34.03 + Double(i) * 0.0001, -118.7)
        }
        let traj = TrajectoryProcessor().process(samples)
        print("P4b backwards ts: kept=\(traj.points.count) rejected=\(traj.rejectedSampleCount) dur=\(traj.duration)")
        let strictlyIncreasing = zip(traj.points, traj.points.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp }
        print("P4b output strictly increasing = \(strictlyIncreasing)")
        #expect(strictlyIncreasing, "P4b FAIL: contract says output timestamps are strictly increasing")
    }

    @Test("P4c: gigantic / NaN timestamps")
    func giganticTimestamps() {
        let samples = [
            Self.gps(0, 34.03, -118.7),
            Self.gps(1e18, 34.031, -118.7),
            Self.gps(1e18 + 1, 34.032, -118.7),
            Self.gps(.nan, 34.033, -118.7),
            Self.gps(.infinity, 34.034, -118.7),
        ]
        let traj = TrajectoryProcessor().process(samples)
        print("P4c kept=\(traj.points.count) rejected=\(traj.rejectedSampleCount) dur=\(traj.duration) gaps=\(traj.gaps.count)")
        for g in traj.gaps { print("  P4c gap \(g.startTime)->\(g.endTime) dur=\(g.duration) \(g.reason)") }
        let out = RunEvaluationPipeline.evaluate(gps: samples, imu: [], route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        print("P4c pipeline score=\(out?.score.finalScore ?? -1) verdict=\(String(describing: out?.integrity.verdict))")
        if let s = out?.score.finalScore {
            #expect(s >= 0 && s <= 10_000, "P4c FAIL: score \(s) out of range")
        }
    }

    // MARK: - P5 pathological runs

    @Test("P5a: driver never moves")
    func neverMoves() {
        let samples = (0..<600).map { i in
            Self.gps(1000 + Double(i), Self.route[0].latitude, Self.route[0].longitude, speed: 0)
        }
        let imu = (0..<600).map { i in
            IMUSample(timestamp: 1000 + Double(i), accelX: 0, accelY: 0, accelZ: 1,
                      gyroX: 0, gyroY: 0, gyroZ: 0)
        }
        let out = RunEvaluationPipeline.evaluate(gps: samples, imu: imu, route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        if let out {
            print("P5a never-moves: score=\(out.score.finalScore) verdict=\(out.integrity.verdict) flags=\(out.integrity.findings.map(\.flag.rawValue)) gates=\(out.gatesHit) dist=\(out.trajectory.totalDistanceMeters) dur=\(out.trajectory.duration)")
            print("P5a breakdown pace=\(out.score.breakdown.paceBps) smooth=\(out.score.breakdown.smoothnessBps) ctrl=\(out.score.breakdown.controlBps) legal=\(out.score.breakdown.complianceBps)")
        } else { print("P5a nil") }
    }

    @Test("P5b: run 10x longer than the course (loop the route 10 times)")
    func tenXRun() {
        var samples: [GPSSample] = []
        var t = 1000.0
        for _ in 0..<10 {
            for c in Self.route {
                samples.append(GPSSample(timestamp: t, coordinate: c, horizontalAccuracy: 5,
                                         course: 90, speed: 15))
                t += 1
            }
        }
        let out = RunEvaluationPipeline.evaluate(gps: samples, imu: [], route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        if let out {
            print("P5b 10x: score=\(out.score.finalScore) verdict=\(out.integrity.verdict) flags=\(out.integrity.findings.map(\.flag.rawValue)) gates=\(out.gatesHit) dist=\(out.trajectory.totalDistanceMeters) dur=\(out.trajectory.duration) dev=\(out.deviationDetected)")
            print("P5b pace bps = \(out.score.breakdown.paceBps) (benchmark 300s, actual \(out.trajectory.duration)s)")
        } else { print("P5b nil") }
    }

    @Test("P5c: IMU samples with NO GPS at all")
    func imuOnly() {
        let imu = (0..<600).map { i in
            IMUSample(timestamp: 1000 + Double(i) / 50, accelX: 0.02, accelY: 0.01, accelZ: 1,
                      gyroX: 0, gyroY: 0, gyroZ: 0.01)
        }
        let out = RunEvaluationPipeline.evaluate(gps: [], imu: imu, route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        if let out {
            print("P5c imu-only: score=\(out.score.finalScore) verdict=\(out.integrity.verdict) flags=\(out.integrity.findings.map(\.flag.rawValue)) gates=\(out.gatesHit) conf=\(out.confidence.score) points=\(out.trajectory.points.count)")
            print("P5c breakdown pace=\(out.score.breakdown.paceBps) smooth=\(out.score.breakdown.smoothnessBps) ctrl=\(out.score.breakdown.controlBps) legal=\(out.score.breakdown.complianceBps)")
        } else { print("P5c nil") }
    }

    @Test("P5d: totally empty run (no gps, no imu)")
    func emptyRun() {
        let out = RunEvaluationPipeline.evaluate(gps: [], imu: [], route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        if let out {
            print("P5d empty: score=\(out.score.finalScore) verdict=\(out.integrity.verdict) flags=\(out.integrity.findings.map(\.flag.rawValue)) gates=\(out.gatesHit)")
        } else { print("P5d nil") }
    }

    @Test("P5e: benchmarkSeconds = 0 / negative / NaN")
    func badBenchmark() {
        let run = TelemetrySimulator(profile: .normal, seed: 4).simulate(route: Self.route)
        for b in [0.0, -300.0, Double.nan, Double.infinity] {
            let out = RunEvaluationPipeline.evaluate(gps: run.gps, imu: run.imu, route: Self.route,
                                                     gates: Self.gates(), benchmarkSeconds: b,
                                                     scoringConfig: Self.scoringConfig)
            print("P5e benchmark=\(b): score=\(out?.score.finalScore ?? -1) pace=\(out?.score.breakdown.paceBps ?? -1)")
            if let s = out?.score.finalScore {
                #expect(s >= 0 && s <= 10_000, "P5e FAIL benchmark=\(b) score=\(s)")
            }
        }
    }

    // MARK: - P6 ghost edge cases

    @Test("P6: ghost gap math edge cases")
    func ghostEdges() {
        // Empty ghost
        let empty = GhostTrajectory(points: [], totalSeconds: 0)
        print("P6 empty ghost elapsed(0.5)=\(empty.elapsedSeconds(atProgress: 0.5)) gap=\(GhostEngine.gapSeconds(elapsedSeconds: 42, progress: 0.5, against: empty))")

        // Single-point ghost
        let single = GhostTrajectory(points: [GhostPoint(progress: 0, elapsedSeconds: 0)], totalSeconds: 0)
        print("P6 single ghost elapsed(0.5)=\(single.elapsedSeconds(atProgress: 0.5)) elapsed(1.0)=\(single.elapsedSeconds(atProgress: 1))")

        // Ghost with a big gap in the middle (no points between 0.1 and 0.9)
        let gappy = GhostTrajectory(points: [
            GhostPoint(progress: 0, elapsedSeconds: 0),
            GhostPoint(progress: 0.1, elapsedSeconds: 10),
            GhostPoint(progress: 0.9, elapsedSeconds: 300),
            GhostPoint(progress: 1.0, elapsedSeconds: 310),
        ], totalSeconds: 310)
        print("P6 gappy elapsed(0.5)=\(gappy.elapsedSeconds(atProgress: 0.5)) (linear interp across the hole)")

        // NON-MONOTONE ghost (hostile / corrupt server payload)
        let bad = GhostTrajectory(points: [
            GhostPoint(progress: 0, elapsedSeconds: 0),
            GhostPoint(progress: 0.8, elapsedSeconds: 100),
            GhostPoint(progress: 0.2, elapsedSeconds: 200),
            GhostPoint(progress: 1.0, elapsedSeconds: 300),
        ], totalSeconds: 300)
        for p in [0.1, 0.3, 0.5, 0.85] {
            print("P6 NON-MONOTONE ghost elapsed(\(p))=\(bad.elapsedSeconds(atProgress: p))")
        }

        // NaN progress query
        print("P6 NaN progress -> elapsed=\(gappy.elapsedSeconds(atProgress: .nan)) gap=\(GhostEngine.gapSeconds(elapsedSeconds: 10, progress: .nan, against: gappy))")
        // out-of-range progress
        print("P6 progress=-5 -> \(gappy.elapsedSeconds(atProgress: -5)); progress=99 -> \(gappy.elapsedSeconds(atProgress: 99))")

        // NaN inside the ghost points
        let nanGhost = GhostTrajectory(points: [
            GhostPoint(progress: 0, elapsedSeconds: 0),
            GhostPoint(progress: .nan, elapsedSeconds: .nan),
            GhostPoint(progress: 1, elapsedSeconds: 100),
        ], totalSeconds: 100)
        print("P6 NaN-point ghost elapsed(0.5)=\(nanGhost.elapsedSeconds(atProgress: 0.5))")
    }

    @Test("P6b: ghost much shorter / much longer than your run")
    func ghostLengthMismatch() {
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 9).simulate(route: Self.route)
        let traj = TrajectoryProcessor().process(run.gps)
        guard let ghost = try? GhostEngine.generate(trajectory: traj, polyline: Self.route,
                                                    checkpoints: Self.gates()) else {
            Issue.record("ghost generate failed"); return
        }
        print("P6b ghost: points=\(ghost.points.count) total=\(ghost.totalSeconds)")
        // Ghost from a SHORTER course used against a longer run: gap at progress 1
        print("P6b gap at progress 1.0 elapsed=10000 -> \(GhostEngine.gapSeconds(elapsedSeconds: 10000, progress: 1.0, against: ghost))")
        print("P6b gap at progress 0.0 elapsed=0 -> \(GhostEngine.gapSeconds(elapsedSeconds: 0, progress: 0, against: ghost))")

        // Ghost generation on a DIFFERENT course than the trajectory came from
        let other = TelemetrySimulator.demoRoute(seed: 12345)
        let g2 = try? GhostEngine.generate(trajectory: traj, polyline: other,
                                           checkpoints: [Checkpoint(sequence: 0, center: other[0], radiusMeters: 1e9)])
        print("P6b ghost on WRONG course: \(g2 == nil ? "threw" : "points=\(g2!.points.count) total=\(g2!.totalSeconds)")")
    }

    // MARK: - P7 scoring config

    @Test("P7: scoring config version mismatch / invalid config")
    func configVersioning() {
        var cfg = Self.scoringConfig
        print("P7 canonical version=\(cfg.version) isValid=\(cfg.isValid)")
        cfg.version = "99.0.0-bogus"
        let run = TelemetrySimulator(profile: .normal, seed: 4).simulate(route: Self.route)
        let out = RunEvaluationPipeline.evaluate(gps: run.gps, imu: run.imu, route: Self.route,
                                                 gates: Self.gates(), benchmarkSeconds: 300,
                                                 scoringConfig: cfg)
        print("P7 bogus version accepted? score=\(out?.score.finalScore ?? -1) stampedVersion=\(out?.score.scoringVersion ?? "nil")")

        // Structurally INVALID config: does anything reject it?
        var broken = Self.scoringConfig
        broken.smoothness.eventComponentBps = 7777
        broken.smoothness.jerkComponentBps = 1111
        print("P7 broken.isValid=\(broken.isValid)")
        let out2 = RunEvaluationPipeline.evaluate(gps: run.gps, imu: run.imu, route: Self.route,
                                                  gates: Self.gates(), benchmarkSeconds: 300,
                                                  scoringConfig: broken)
        print("P7 INVALID config still scored: score=\(out2?.score.finalScore ?? -1) smoothBps=\(out2?.score.breakdown.smoothnessBps ?? -1)")

        // Does ScoringConfig.load reject an invalid config?
        let brokenJSON = try! JSONEncoder().encode(broken)
        let loaded = try? ScoringConfig.load(from: brokenJSON)
        print("P7 ScoringConfig.load(invalid) = \(loaded == nil ? "threw (good)" : "ACCEPTED (bad)")")

        // Weights that sum to something other than 100
        var w = Self.scoringConfig
        w.weights = ScoringWeights(paceBps: 9000, smoothnessBps: 9000, controlBps: 9000, complianceBps: 9000)
        print("P7 oversized weights isValid=\(w.isValid)")
        let out3 = RunEvaluationPipeline.evaluate(gps: run.gps, imu: run.imu, route: Self.route,
                                                  gates: Self.gates(), benchmarkSeconds: 300,
                                                  scoringConfig: w)
        print("P7 oversized weights score=\(out3?.score.finalScore ?? -1) (>10000 means overflow of the 0..10000 contract)")
    }

    // MARK: - P8 DriveSession lifecycle

    @Test("P8a: abort BEFORE start, and double start")
    func abortBeforeStart() async {
        let s = DriveSession(polyline: Self.route, gates: Self.gates(),
                             benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)!
        await s.abort()
        print("P8a state after abort-before-start = \(await s.state)")
        // Now try to start after abort:
        let stream = AsyncStream<SensorEvent> { $0.finish() }
        await s.start(events: stream)
        print("P8a state after start-following-abort = \(await s.state)")
    }

    @Test("P8b: stream that never yields anything")
    func emptyStream() async {
        let s = DriveSession(polyline: Self.route, gates: Self.gates(),
                             benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)!
        let stream = AsyncStream<SensorEvent> { $0.finish() }
        await s.start(events: stream)
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("P8b state after empty stream = \(await s.state)")
    }

    @Test("P8c: session where gates can never be hit (radius 0) — does it hang or fail?")
    func unreachableGates() async {
        let s = DriveSession(polyline: Self.route, gates: Self.gates(radius: 0),
                             benchmarkSeconds: 300, scoringConfig: Self.scoringConfig)!
        let run = TelemetrySimulator(profile: .normal, seed: 3).simulate(route: Self.route)
        let events = SensorEvent.merge(gps: run.gps, imu: run.imu)
        let stream = AsyncStream<SensorEvent> { c in
            for e in events { c.yield(e) }
            c.finish()
        }
        await s.start(events: stream)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("P8c state with radius-0 gates = \(await s.state)")
    }

    @Test("P8d: DriveSession with ZERO gates — can it ever finish?")
    func zeroGateSession() async {
        guard let s = DriveSession(polyline: Self.route, gates: [],
                                   benchmarkSeconds: 300, scoringConfig: Self.scoringConfig) else {
            print("P8d DriveSession(no gates) = nil"); return
        }
        let run = TelemetrySimulator(profile: .normal, seed: 3).simulate(route: Self.route)
        let events = SensorEvent.merge(gps: run.gps, imu: run.imu)
        let stream = AsyncStream<SensorEvent> { c in
            for e in events { c.yield(e) }
            c.finish()
        }
        await s.start(events: stream)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        print("P8d state with ZERO gates = \(await s.state)")
    }

    // MARK: - P9 integrity boundaries

    @Test("P9: integrity verdict on a hostile 'perfect teleport' run")
    func integrityBoundaries() {
        // A run that is ONLY the 4 gate coordinates, 1 second apart: instant
        // finish, all gates hit, nothing in between.
        let g = Self.gates()
        let samples = g.enumerated().map { i, gate in
            GPSSample(timestamp: 1000 + Double(i), coordinate: gate.center,
                      horizontalAccuracy: 5, course: 90, speed: 15)
        }
        let out = RunEvaluationPipeline.evaluate(gps: samples, imu: [], route: Self.route,
                                                 gates: g, benchmarkSeconds: 300,
                                                 scoringConfig: Self.scoringConfig)
        if let out {
            print("P9 4-point teleport run: score=\(out.score.finalScore) verdict=\(out.integrity.verdict) flags=\(out.integrity.findings.map(\.flag.rawValue)) gates=\(out.gatesHit) dist=\(out.trajectory.totalDistanceMeters) dur=\(out.trajectory.duration) conf=\(out.confidence.score)")
        } else { print("P9 nil") }
    }
}
