import Foundation
import SOSync

/// Adapts the Kit's transport seam to the real Supabase uploader, so the
/// offline queue can retry a run long after the screen that produced it is
/// gone. Throwing means "not acknowledged" — the queue keeps the run.
struct QueuedRunUploader: RunUploading {
    let api: SupabaseAPI?

    func upload(_ run: PendingRun) async throws {
        guard let api else { throw SupabaseAPI.APIError.notConfigured }
        guard let current = await api.userId else {
            throw SupabaseAPI.APIError.notAuthenticated
        }
        // Belt and braces with the queue's own check: a drive recorded by a
        // different account must never reach this one's leaderboard.
        if let owner = run.userId, owner != current {
            throw SupabaseAPI.APIError.notAuthenticated
        }
        _ = try await RunUploader(api: api).upload(
            outcome: run.outcome,
            courseId: run.courseId
        )
    }
}
