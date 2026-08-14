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
            gpsFreshSeconds: 3, startMovingMeters: 5, maxWaitingSeconds: 30
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
            gpsFreshSeconds: 3, startMovingMeters: 5, maxWaitingSeconds: 10
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
            gpsFreshSeconds: 3, startMovingMeters: 5,
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

    // MARK: - One device, two drivers

    @Test("a crashed drive is never handed to the next person who signs in")
    func journalIsAccountScoped() async throws {
        // Driver A drives, the app is killed mid-run, A signs out, B signs
        // in. Without an owner on the journal, A's GPS trace is recovered
        // and uploaded to B's account — someone else's drive on someone
        // else's leaderboard. PendingRun already learned this; the journal
        // had to learn it too.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("owner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "course-a", startedAt: 11_000,
            userId: "driver-A", flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 31).simulate(route: Self.route)
        await recorder.record(gps: Array(run.gps.prefix(20)), imu: [])

        let recovered = try #require(InFlightRecorder.recover(in: dir).first)
        #expect(recovered.userId == "driver-A", "the journal must remember who drove")
        #expect(!recovered.belongs(to: "driver-B"), "B must not be given A's drive")
        #expect(!recovered.belongs(to: nil), "a signed-out session must not claim A's drive")
        #expect(recovered.belongs(to: "driver-A"), "A gets their own drive back")
    }

    @Test("a drive recorded signed out is claimable by whoever signs in")
    func unownedJournalIsClaimable() async throws {
        // The app drives, scores and queues signed out by design, so an
        // unowned journal is not an error — it belongs to whoever this
        // device's driver turns out to be. Same rule the upload queue
        // already applies to an unowned pending run.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unowned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "course-b", startedAt: 12_000, flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 32).simulate(route: Self.route)
        await recorder.record(gps: Array(run.gps.prefix(20)), imu: [])

        let recovered = try #require(InFlightRecorder.recover(in: dir).first)
        #expect(recovered.userId == nil)
        #expect(recovered.belongs(to: "anyone"))
        #expect(recovered.belongs(to: nil))
    }

    @Test("journalled samples come back in the order they were recorded")
    func journalPreservesOrder() async throws {
        // The first version spawned a Task per sample. Independent tasks
        // calling an actor have NO ordering guarantee, so at 50 Hz the file
        // could hold samples shuffled — a recovered drive with a scrambled
        // timeline is worse than no file at all.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("order-in-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = try InFlightRecorder(
            directory: dir, courseId: "order", startedAt: 7_000, flushEvery: 1
        )
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 21).simulate(route: Self.route)
        // Batches, exactly as the session hands them over.
        for chunk in stride(from: 0, to: 300, by: 50) {
            await recorder.record(
                gps: Array(run.gps[chunk..<min(chunk + 50, run.gps.count)]),
                imu: []
            )
        }
        let recovered = try #require(InFlightRecorder.recover(in: dir).first)
        let stamps = recovered.gps.map(\.timestamp)
        #expect(stamps == stamps.sorted(), "the journal came back out of order")
        #expect(stamps == Array(run.gps.prefix(stamps.count)).map(\.timestamp))
    }

    @Test("a finished run keeps its journal until the app has queued it")
    func journalSurvivesFinish() async throws {
        // The window between "the pipeline produced a result" and "the app
        // put it in the upload queue" is exactly the window this file
        // exists to protect. Deleting it at finish reopened it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = Self.session(config: .default)
        let recorder = try InFlightRecorder(
            directory: dir, courseId: "demo", startedAt: 8_000, flushEvery: 1
        )
        await session.attach(recorder: recorder)
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 22).simulate(route: Self.route)
        let state = await Self.drain(session, SensorEvent.merge(gps: run.gps, imu: run.imu))
        guard case .finished = state else {
            Issue.record("expected a finished run, got \(state)")
            return
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(
            !InFlightRecorder.recover(in: dir).isEmpty,
            "the journal was deleted before anyone could queue the run"
        )
    }

    @Test("an aborted run leaves nothing to recover")
    func abortDiscardsTheJournal() async throws {
        // A driver who ends a run has decided it does not count. Offering it
        // back on next launch would be the app arguing with them.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("abort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = Self.session(config: .default)
        let recorder = try InFlightRecorder(
            directory: dir, courseId: "demo", startedAt: 9_500, flushEvery: 1
        )
        await session.attach(recorder: recorder)
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 24).simulate(route: Self.route)
        let events = Array(SensorEvent.merge(gps: run.gps, imu: run.imu).prefix(600))
        let stream = AsyncStream<SensorEvent> { c in
            for e in events { c.yield(e) }
            c.finish()
        }
        await session.start(events: stream)
        try await Task.sleep(for: .milliseconds(150))
        await session.abort()
        try await Task.sleep(for: .milliseconds(150))
        #expect(InFlightRecorder.recover(in: dir).isEmpty, "an aborted run was left on disk")
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
