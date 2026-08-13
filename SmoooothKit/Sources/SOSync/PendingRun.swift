import Foundation
import SOModels

/// A finished run waiting to reach the server (spec §60).
///
/// This is the durable record: everything the uploader needs to submit the
/// run later, plus the queue bookkeeping. A drive is the most expensive
/// thing a user can produce in this app — it is written to disk before any
/// network call is attempted, and it is never deleted until the server has
/// acknowledged it.
public struct PendingRun: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let courseId: String
    /// Who recorded this drive. nil = recorded while signed out, so the
    /// next account to sign in adopts it. A non-nil value that doesn't
    /// match the current user must NEVER upload — otherwise signing out
    /// and signing in as someone else silently posts your drive to their
    /// account and their leaderboard.
    public let userId: String?
    public let outcome: DriveRunOutcome
    public let createdAt: Date
    public var state: UploadState
    public var attempts: Int
    /// Last failure, kept for support and for honest UI ("why is this stuck?").
    public var lastError: String?
    public var lastAttemptAt: Date?

    public init(
        id: UUID = UUID(),
        courseId: String,
        userId: String? = nil,
        outcome: DriveRunOutcome,
        createdAt: Date = Date(),
        state: UploadState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.courseId = courseId
        self.userId = userId
        self.outcome = outcome
        self.createdAt = createdAt
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
    }

    /// Exponential backoff with a ceiling: a run that keeps failing must not
    /// hammer the network, but it must also never stop trying — the user's
    /// drive is not disposable. 30s, 1m, 2m, 4m … capped at 30 minutes.
    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let capped = min(attempts, 7)
        return min(30 * pow(2, Double(capped - 1)), 1_800)
    }

    /// True when the queue may try this run again at `now`.
    public func isReady(at now: Date) -> Bool {
        guard state == .pending || state == .failed else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= Self.backoff(afterAttempts: attempts)
    }
}
