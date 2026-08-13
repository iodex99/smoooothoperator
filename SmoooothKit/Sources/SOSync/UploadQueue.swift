import Foundation

/// The transport seam. The Kit never speaks HTTP; the iOS layer conforms
/// this to the real Supabase uploader, tests conform it to fakes.
public protocol RunUploading: Sendable {
    /// Submits a run. Returning normally means the SERVER has acknowledged
    /// it — only then may the queue forget the run.
    func upload(_ run: PendingRun) async throws
}

/// Offline-first upload queue (spec §60).
///
/// A finished run is persisted BEFORE any network call and is removed only
/// after the server acknowledges it. Crash, airplane mode, force-quit,
/// dead battery mid-upload: the run survives and is retried on the next
/// flush. Nothing here deletes a user's drive on failure.
public actor UploadQueue {
    private let store: RunStore
    private let uploader: RunUploading
    private let now: @Sendable () -> Date
    private var flushing = false

    public init(
        store: RunStore,
        uploader: RunUploading,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.uploader = uploader
        self.now = now
    }

    /// Persists a finished run. Call this the moment a drive finishes —
    /// before attempting upload — so the drive is durable even if the app
    /// dies during the network call.
    @discardableResult
    public func enqueue(
        courseId: String,
        outcome: DriveRunOutcome,
        userId: String? = nil
    ) throws -> PendingRun {
        let run = PendingRun(
            courseId: courseId,
            userId: userId,
            outcome: outcome,
            createdAt: now()
        )
        try store.save(run)
        return run
    }

    public func pendingCount() throws -> Int {
        try store.loadAll().count
    }

    /// Drops a run the caller uploaded directly (the finish-screen fast path
    /// still wants the server's authoritative score immediately). Only ever
    /// called after the server acknowledged the run.
    public func acknowledge(id: UUID) {
        try? store.delete(id: id)
    }

    public func pending() throws -> [PendingRun] {
        try store.loadAll()
    }

    /// Result of one flush pass — enough for honest UI ("2 runs waiting").
    public struct FlushSummary: Sendable, Equatable {
        public var uploaded: Int = 0
        public var failed: Int = 0
        public var skipped: Int = 0
        public var remaining: Int = 0
    }

    /// Attempts every run whose backoff has elapsed, oldest first.
    ///
    /// Re-entrant calls are ignored rather than queued: a foreground event
    /// storm must not multiply in-flight uploads of the same run.
    /// Uploads only what the CURRENT account may claim. Pass the signed-in
    /// user id; runs recorded while signed out (nil owner) are adopted, and
    /// runs belonging to a different account are left untouched.
    @discardableResult
    public func flush(currentUserId: String? = nil) async -> FlushSummary {
        guard !flushing else { return FlushSummary() }
        flushing = true
        defer { flushing = false }

        var summary = FlushSummary()
        let runs = (try? store.loadAll()) ?? []
        for var run in runs {
            // A run left mid-flight by a crash is owed another attempt, not
            // abandoned in `.uploading` forever.
            if run.state == .uploading {
                run.state = .pending
            }
            // Never post someone else's drive to the account signed in now.
            if let owner = run.userId, owner != currentUserId {
                summary.skipped += 1
                continue
            }
            guard run.isReady(at: now()) else {
                summary.skipped += 1
                continue
            }

            run.state = .uploading
            run.lastAttemptAt = now()
            try? store.save(run)

            do {
                try await uploader.upload(run)
                // Acknowledged by the server: only now is it safe to forget.
                try? store.delete(id: run.id)
                summary.uploaded += 1
            } catch {
                run.state = .failed
                run.attempts += 1
                run.lastError = String(describing: error)
                try? store.save(run)
                summary.failed += 1
            }
        }
        summary.remaining = (try? store.loadAll().count) ?? 0
        return summary
    }
}
