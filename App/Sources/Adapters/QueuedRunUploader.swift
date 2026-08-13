import Foundation
import SOSync

/// Adapts the Kit's transport seam to the real Supabase uploader, so the
/// offline queue can retry a run long after the screen that produced it is
/// gone. Throwing means "not acknowledged" — the queue keeps the run.
struct QueuedRunUploader: RunUploading {
    let api: SupabaseAPI?

    func upload(_ run: PendingRun) async throws {
        guard let api else { throw SupabaseAPI.APIError.notConfigured }
        guard await api.userId != nil else { throw SupabaseAPI.APIError.notAuthenticated }
        _ = try await RunUploader(api: api).upload(
            outcome: run.outcome,
            courseId: run.courseId
        )
    }
}
