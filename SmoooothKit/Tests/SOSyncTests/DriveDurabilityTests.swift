import Foundation
import SOCore
import SOCourse
import SOScoring
import SOSimulator
import SOTelemetry
import Testing
@testable import SOSync

/// Two audit findings, both about a drive existing in exactly one place:
///
///   * a parked session buffered IMU at 50 Hz until iOS killed the app;
///   * a crash mid-drive destroyed the whole run, because the upload queue
///     only ever protected a *finished* one.
@Suite("A drive survives the phone")
struct DriveDurabilityTests {
    static let route = TelemetrySimulator.demoRoute(seed: 7)

    static let scoringConfig: ScoringConfig = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("configs/scoring/v1.json")
        return try! ScoringConfig.load(from: Data(contentsOf: url))
    }()

    static func gates() -> [Checkpoint] {
        [0, route.count / 2, route.count - 1].enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 45)
        }
    }

    static func session(config: DriveSessionConfig) -> DriveSession {
        DriveSession(
            polyline: route,
            gates: gates(),
            benchmarkSeconds: 300,
            scoringConfig: scoringConfig,
            config: config
        )!
    }

    /// A stationary phone: real GPS keeps reporting, real IMU keeps ticking,
    /// and nothing ever crosses the start gate.
    static func parkedEvents(seconds: Double, from origin: GeoCoordinate) -> [SensorEvent] {
        var events: [SensorEvent] = []
        var t = 0.0
        while t < seconds {
            events.append(.gps(GPSSample(
                timestamp: t, coordinate: origin,
                horizontalAccuracy: 5, course: 0, speed: 0
            )))
            for step in 0..<5 {
                events.append(.imu(IMUSample(
                    timestamp: t + Double(step) * 0.02,
                    accelX: 0, accelY: 0, accelZ: 1,
                    gyroX: 0, gyroY: 0, gyroZ: 0
                )))
            }
            t += 0.1
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    static func drain(_ session: DriveSession, _ events: [SensorEvent]) async -> DriveSessionState {
        let states = await session.states()
        let stream = AsyncStream<SensorEvent> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        await session.start(events: stream)
        for await state in states {
            if case .finished = state { return state }
            if case .failed = state { return state }
        }
        return await session.state
    }

    // MARK: - The memory ceiling

    @Test("a session parked on the ready screen gives up instead of growing")
    func parkedSessionTimesOut() async {
        let config = DriveSessionConfig(
            gpsFreshSeconds: 3, startMovingSpeedMps: 1.5, maxWaitingSeconds: 30
        )
        let session = Self.session(config: config)
        // Five minutes of a phone sitting on a dashboard.
        let state = await Self.drain(session, Self.parkedEvents(seconds: 300, from: Self.route[0]))

        guard case .failed(let reason) = state else {
            Issue.record("a parked session must end, got \(state)")
            return
        }
        #expect(reason.contains("timed out"), "the driver should be told why: \(reason)")
    }

    @Test("giving up releases the buffers rather than holding them")
    func timeoutReleasesMemory() async {
        let config = DriveSessionConfig(
            gpsFreshSeconds: 3, startMovingSpeedMps: 1.5, maxWaitingSeconds: 10
        )
        let session = Self.session(config: config)
        _ = await Self.drain(session, Self.parkedEvents(seconds: 200, from: Self.route[0]))
        // The whole point of the ceiling is not to be holding the samples.
        let held = await session.bufferedSampleCount
        #expect(held == 0, "\(held) samples still held after giving up")
    }

    @Test("the sample cap catches a stream whose timestamps do not advance")
    func sampleCapCatchesFrozenClock() async {
        // A sensor that reports the same instant forever defeats every
        // duration-based limit. The count-based one is the backstop.
        let config = DriveSessionConfig(
            gpsFreshSeconds: 3, startMovingSpeedMps: 1.5,
            maxWaitingSeconds: 600, maxRunSeconds: 7_200,
            maxIMUSamples: 200, maxGPSSamples: 200
        )
        let session = Self.session(config: config)
        let frozen = (0..<5_000).map { _ in
            SensorEvent.imu(IMUSample(
                timestamp: 100, accelX: 0, accelY: 0, accelZ: 1,
                gyroX: 0, gyroY: 0, gyroZ: 0
            ))
        }
        let state = await Self.drain(session, frozen)
        guard case .failed(let reason) = state else {
            Issue.record("a frozen clock must still be capped, got \(state)")
            return
        }
        #expect(reason.contains("buffer limit"))
        let held = await session.bufferedSampleCount
        #expect(held == 0)
    }

    @Test("a normal drive is never cut short by the ceilings")
    func realDriveIsUnaffected() async {
        // The ceilings must be generous enough that a real run never meets
        // them — a limit that ends legitimate drives is worse than the leak.
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 3).simulate(route: Self.route)
        let events = SensorEvent.merge(gps: run.gps, imu: run.imu)
        let session = Self.session(config: .default)
        let state = await Self.drain(session, events)
        guard case .finished = state else {
            Issue.record("a clean drive must finish, got \(state)")
            return
        }
    }

    // MARK: - Surviving a crash

    @Test("a drive is on disk before it finishes")
    func recorderWritesDuringTheRun() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "course-1", startedAt: 1_000, flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 11).simulate(route: Self.route)
        for sample in run.gps.prefix(40) { await recorder.record(gps: sample) }
        for sample in run.imu.prefix(80) { await recorder.record(imu: sample) }

        // Deliberately do NOT call finish(): this is what a crash looks like.
        let recovered = InFlightRecorder.recover(in: dir)
        #expect(recovered.count == 1, "the interrupted drive must be recoverable")
        #expect(recovered.first?.courseId == "course-1", "recovery has to know which course")
        #expect(recovered.first?.gps.count == 40)
        #expect(recovered.first?.imu.count == 80)
    }

    @Test("a file torn mid-write keeps everything before the tear")
    func tornFileRecoversWhatItCan() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("torn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "course-2", startedAt: 2_000, flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 12).simulate(route: Self.route)
        for sample in run.gps.prefix(30) { await recorder.record(gps: sample) }

        // Chop the file mid-line, exactly as a power loss would.
        let url = InFlightRecorder.url(in: dir, startedAt: 2_000)
        var data = try Data(contentsOf: url)
        data = data.prefix(data.count - 17)
        try data.write(to: url)

        let recovered = InFlightRecorder.recover(in: dir)
        #expect(recovered.count == 1, "a torn file must not lose the whole drive")
        let count = recovered.first?.gps.count ?? 0
        #expect(count >= 28 && count <= 30, "expected ~29 intact fixes, got \(count)")
    }

    @Test("a finished run leaves nothing to recover")
    func finishRemovesTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "course-3", startedAt: 3_000, flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 13).simulate(route: Self.route)
        for sample in run.gps.prefix(10) { await recorder.record(gps: sample) }
        await recorder.finish()

        // Otherwise every completed drive would be re-offered on next launch.
        #expect(InFlightRecorder.recover(in: dir).isEmpty)
    }

    @Test("a session that never moved is not offered back to the driver")
    func headerOnlyIsNotARun() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try InFlightRecorder(directory: dir, courseId: "course-4", startedAt: 4_000)
        #expect(
            InFlightRecorder.recover(in: dir).isEmpty,
            "a file with no fixes is not a drive worth recovering"
        )
    }

    @Test("recovered drives come back in the order they were driven")
    func recoveryIsOrdered() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = TelemetrySimulator(profile: .fastSmooth, seed: 14).simulate(route: Self.route)
        for (index, started) in [5_000.0, 1_000.0, 3_000.0].enumerated() {
            let recorder = try InFlightRecorder(
                directory: dir, courseId: "course-\(index)", startedAt: started, flushEvery: 1
            )
            for sample in run.gps.prefix(5) { await recorder.record(gps: sample) }
        }
        let recovered = InFlightRecorder.recover(in: dir)
        #expect(recovered.map(\.startedAt) == [1_000, 3_000, 5_000])
    }

    @Test("a session writes to its recorder as the drive happens")
    func sessionFeedsTheRecorder() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = Self.session(config: .default)
        let recorder = try InFlightRecorder(
            directory: dir, courseId: "demo", startedAt: 9_000, flushEvery: 1
        )
        await session.attach(recorder: recorder)

        let run = TelemetrySimulator(profile: .fastSmooth, seed: 15).simulate(route: Self.route)
        let events = Array(SensorEvent.merge(gps: run.gps, imu: run.imu).prefix(400))
        let stream = AsyncStream<SensorEvent> { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
        let states = await session.states()
        await session.start(events: stream)
        for await state in states {
            if case .failed = state { break }
            if case .finished = state { break }
        }
        // The stream ended mid-run, which is what a crash looks like from
        // the recorder's side: the file must still hold the drive so far.
        try await Task.sleep(for: .milliseconds(120))
        let recovered = InFlightRecorder.recover(in: dir)
        #expect(!recovered.isEmpty, "the session must have written as it went")
        #expect((recovered.first?.gps.count ?? 0) > 0)
    }
}
