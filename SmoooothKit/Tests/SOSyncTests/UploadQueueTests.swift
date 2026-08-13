import Foundation
import SOModels
import SOScoring
import SOTelemetry
import Testing
@testable import SOSync

/// The durability contract (spec §60): a finished drive survives crashes,
/// airplane mode, force-quits and corrupt neighbours, and is never deleted
/// until the server has acknowledged it.
@Suite("UploadQueue durability")
struct UploadQueueTests {
    // MARK: - Fixtures

    static func outcome(score: Int = 8_800) -> DriveRunOutcome {
        DriveRunOutcome(
            provisionalScore: score,
            provisionalVerdict: .verified,
            breakdown: ScoreBreakdown(
                paceBps: 9_000, smoothnessBps: 8_000,
                controlBps: 9_500, complianceBps: 10_000
            ),
            confidenceScore: 92,
            durationSeconds: 195,
            distanceMeters: 4_300,
            gatesHit: 4,
            deviationDetected: false,
            rawGPS: [
                GPSSample(
                    timestamp: 1_000,
                    coordinate: .init(latitude: 34.02, longitude: -118.78),
                    altitude: 40,
                    horizontalAccuracy: 5,
                    course: 90, speed: 22
                )
            ],
            rawIMU: [
                IMUSample(
                    timestamp: 1_000,
                    accelX: 0.1, accelY: 0.2, accelZ: 9.8,
                    gyroX: 0, gyroY: 0, gyroZ: 0
                )
            ]
        )
    }

    /// Uploader whose behavior each test dictates.
    actor ScriptedUploader: RunUploading {
        enum Behavior: Sendable { case succeed, fail }
        private var behavior: Behavior
        private(set) var attempts: [UUID] = []

        init(_ behavior: Behavior = .succeed) { self.behavior = behavior }

        func set(_ behavior: Behavior) { self.behavior = behavior }
        func attemptCount() -> Int { attempts.count }

        struct Offline: Error {}

        func upload(_ run: PendingRun) async throws {
            attempts.append(run.id)
            if behavior == .fail { throw Offline() }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("so-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The core guarantee

    @Test("a finished run is on disk before any upload is attempted")
    func enqueuePersistsImmediately() async throws {
        let directory = try temporaryDirectory()
        let store = try FileRunStore(directory: directory)
        let queue = UploadQueue(store: store, uploader: ScriptedUploader(.fail))

        try await queue.enqueue(courseId: "course-1", outcome: Self.outcome())

        // A COMPLETELY SEPARATE store instance — as after an app restart.
        let reopened = try FileRunStore(directory: directory)
        let runs = try reopened.loadAll()
        #expect(runs.count == 1)
        #expect(runs[0].courseId == "course-1")
        #expect(runs[0].outcome.provisionalScore == 8_800)
        #expect(runs[0].outcome.rawGPS.count == 1, "raw telemetry survives too")
    }

    @Test("a failed upload NEVER deletes the run")
    func failureKeepsTheRun() async throws {
        let store = InMemoryRunStore()
        let uploader = ScriptedUploader(.fail)
        let queue = UploadQueue(store: store, uploader: uploader)

        try await queue.enqueue(courseId: "c", outcome: Self.outcome())
        let summary = await queue.flush()

        #expect(summary.failed == 1)
        #expect(summary.uploaded == 0)
        #expect(summary.remaining == 1)
        let survivors = try store.loadAll()
        #expect(survivors.count == 1)
        #expect(survivors[0].attempts == 1)
        #expect(survivors[0].lastError != nil, "the reason is kept for support")
    }

    @Test("a run is forgotten only after the server acknowledges it")
    func successRemovesTheRun() async throws {
        let store = InMemoryRunStore()
        let queue = UploadQueue(store: store, uploader: ScriptedUploader(.succeed))

        try await queue.enqueue(courseId: "c", outcome: Self.outcome())
        let summary = await queue.flush()

        #expect(summary.uploaded == 1)
        #expect(summary.remaining == 0)
        #expect(try store.loadAll().isEmpty)
    }

    @Test("offline now, online later: the run still lands")
    func retryAfterConnectivityReturns() async throws {
        let store = InMemoryRunStore()
        let uploader = ScriptedUploader(.fail)
        // Clock we control, so backoff is exercised without sleeping.
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 0)
        let queue = UploadQueue(store: store, uploader: uploader, now: { clock })

        try await queue.enqueue(courseId: "c", outcome: Self.outcome())
        _ = await queue.flush()
        #expect(try store.loadAll().count == 1)

        // Backoff has not elapsed: the queue does not hammer the network.
        let tooSoon = await queue.flush()
        #expect(tooSoon.skipped == 1)
        #expect(await uploader.attemptCount() == 1)

        // Time passes, connectivity returns.
        clock = Date(timeIntervalSince1970: 60)
        await uploader.set(.succeed)
        let recovered = await queue.flush()
        #expect(recovered.uploaded == 1)
        #expect(try store.loadAll().isEmpty)
    }

    @Test("a crash mid-upload leaves the run recoverable, not stuck")
    func crashDuringUploadRecovers() async throws {
        let store = InMemoryRunStore()
        // Simulate the state the app died in: marked uploading, never resolved.
        let stranded = PendingRun(
            courseId: "c",
            outcome: Self.outcome(),
            state: .uploading,
            attempts: 0
        )
        try store.save(stranded)

        let queue = UploadQueue(store: store, uploader: ScriptedUploader(.succeed))
        let summary = await queue.flush()

        #expect(summary.uploaded == 1, "a stranded run is retried, not abandoned")
        #expect(try store.loadAll().isEmpty)
    }

    @Test("a corrupt record is quarantined; healthy runs still upload")
    func corruptFileDoesNotBlockTheQueue() async throws {
        let directory = try temporaryDirectory()
        let store = try FileRunStore(directory: directory)
        try store.save(PendingRun(courseId: "good", outcome: Self.outcome()))

        // A truncated/garbage record beside it (disk corruption, schema drift).
        let corrupt = directory.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: corrupt)

        let runs = try store.loadAll()
        #expect(runs.count == 1, "the healthy run still loads")
        #expect(runs[0].courseId == "good")
        #expect(store.quarantinedCount() == 1, "the bad bytes are kept, not destroyed")

        let queue = UploadQueue(store: store, uploader: ScriptedUploader(.succeed))
        let summary = await queue.flush()
        #expect(summary.uploaded == 1)
    }

    @Test("runs upload oldest first")
    func fifoOrdering() async throws {
        let store = InMemoryRunStore()
        let uploader = ScriptedUploader(.succeed)
        let older = PendingRun(
            courseId: "older",
            outcome: Self.outcome(),
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newer = PendingRun(
            courseId: "newer",
            outcome: Self.outcome(),
            createdAt: Date(timeIntervalSince1970: 200)
        )
        try store.save(newer)
        try store.save(older)

        let queue = UploadQueue(store: store, uploader: uploader)
        _ = await queue.flush()

        let order = await uploader.attempts
        #expect(order.first == older.id, "the user's earlier drive goes first")
    }

    @Test("overlapping flushes do not upload the same run twice")
    func reentrantFlushIsSafe() async throws {
        let store = InMemoryRunStore()
        let uploader = ScriptedUploader(.succeed)
        let queue = UploadQueue(store: store, uploader: uploader)
        try await queue.enqueue(courseId: "c", outcome: Self.outcome())

        async let first = queue.flush()
        async let second = queue.flush()
        _ = await (first, second)

        #expect(await uploader.attemptCount() == 1)
    }

    @Test("backoff grows and is capped so a stuck run never spins")
    func backoffSchedule() {
        #expect(PendingRun.backoff(afterAttempts: 0) == 0)
        #expect(PendingRun.backoff(afterAttempts: 1) == 30)
        #expect(PendingRun.backoff(afterAttempts: 2) == 60)
        #expect(PendingRun.backoff(afterAttempts: 3) == 120)
        #expect(PendingRun.backoff(afterAttempts: 20) == 1_800, "capped at 30 minutes")
    }

    @Test("re-saving a run overwrites cleanly and leaves no temp files")
    func atomicOverwrite() throws {
        let directory = try temporaryDirectory()
        let store = try FileRunStore(directory: directory)
        var run = PendingRun(courseId: "c", outcome: Self.outcome())
        try store.save(run)
        run.attempts = 3
        run.lastError = "offline"
        try store.save(run)

        let loaded = try store.loadAll()
        #expect(loaded.count == 1, "one record, not two")
        #expect(loaded[0].attempts == 3)

        let leftovers = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tmp" }
        #expect(leftovers.isEmpty)
    }
}

/// Account switching: one device, two drivers. A queued run must never be
/// posted to whoever happens to be signed in later.
@Suite("Upload queue account ownership")
struct UploadQueueOwnershipTests {
    @Test("a run recorded by another account is never uploaded")
    func foreignRunIsRefused() async throws {
        let store = InMemoryRunStore()
        let uploader = UploadQueueTests.ScriptedUploader(.succeed)
        let queue = UploadQueue(store: store, uploader: uploader)

        try await queue.enqueue(
            courseId: "c",
            outcome: UploadQueueTests.outcome(),
            userId: "driver-A"
        )
        // Driver B is signed in now.
        let summary = await queue.flush(currentUserId: "driver-B")

        #expect(summary.uploaded == 0)
        #expect(await uploader.attemptCount() == 0)
        #expect(try store.loadAll().count == 1, "A's run is kept, not destroyed")
    }

    @Test("the owner signing back in uploads their own run")
    func ownerCanUpload() async throws {
        let store = InMemoryRunStore()
        let uploader = UploadQueueTests.ScriptedUploader(.succeed)
        let queue = UploadQueue(store: store, uploader: uploader)

        try await queue.enqueue(
            courseId: "c",
            outcome: UploadQueueTests.outcome(),
            userId: "driver-A"
        )
        let summary = await queue.flush(currentUserId: "driver-A")
        #expect(summary.uploaded == 1)
    }

    @Test("a run recorded signed out is adopted by whoever signs in")
    func signedOutRunIsAdopted() async throws {
        let store = InMemoryRunStore()
        let uploader = UploadQueueTests.ScriptedUploader(.succeed)
        let queue = UploadQueue(store: store, uploader: uploader)

        // No account existed when this drive was recorded.
        try await queue.enqueue(courseId: "c", outcome: UploadQueueTests.outcome())
        let summary = await queue.flush(currentUserId: "driver-A")
        #expect(summary.uploaded == 1, "the drive you did before signing up still counts")
    }
}
