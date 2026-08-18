import Foundation
import SOSync
import SOTelemetry

/// Uploads a finished run: compact telemetry blob → storage, runs row +
/// envelope → REST, then invokes score-run for the authoritative result
/// (spec §§46, 60). A completed run must never be lost: failures leave the
/// run in the local retry queue (UploadState machine).
///
/// The wire format itself lives in `SOSync.TelemetryBlob` — it used to be
/// here, which put the one format that crosses the language boundary in the
/// half of the project Linux cannot test.
struct RunUploader {
    let api: SupabaseAPI

    struct AuthoritativeResult: Decodable {
        var verdict: String
        var score: Int
        var finished: Bool
    }

    func upload(
        outcome: DriveRunOutcome,
        courseId: String,
        vehicleId: String? = nil
    ) async throws -> AuthoritativeResult {
        guard let userId = await api.userId else { throw SupabaseAPI.APIError.notAuthenticated }

        // Gzipped, and written at each sensor's real resolution: ~6.7× less
        // to send from a car on a mobile connection, and ~6.7× less to store
        // forever. The declared hash is over the COMPRESSED bytes, because
        // that is what the server fetches and checks before decompressing.
        let blob = try TelemetryBlob.upload(gps: outcome.rawGPS, imu: outcome.rawIMU)
        let runStart = outcome.rawGPS.first?.timestamp ?? Date().timeIntervalSince1970

        // 1. Blob first — the run row only exists once its data is safe.
        let storagePath = TelemetryBlob.storagePath(userId: userId)
        try await api.uploadTelemetry(path: storagePath, data: blob.bytes)

        // 2. Run row (status uploaded → server enqueues the scoring job).
        let runResponse = try await api.insert("runs", json: [
            "user_id": userId,
            "course_id": courseId,
            "status": "uploaded",
            "started_at": ISO8601DateFormatter().string(
                from: Date(timeIntervalSince1970: runStart)
            ),
            "duration_seconds": outcome.durationSeconds,
            "distance_meters": outcome.distanceMeters,
            "client_score": outcome.provisionalScore,
        ].merging(vehicleId.map { ["vehicle_id": $0] } ?? [:]) { current, _ in current })
        guard
            let rows = try JSONSerialization.jsonObject(with: runResponse) as? [[String: Any]],
            let runId = rows.first?["id"] as? String
        else { throw SupabaseAPI.APIError.http(500, "run insert returned no id") }

        // 3. Envelope binds the blob to the run.
        _ = try await api.insert("telemetry", json: [
            "run_id": runId,
            "storage_path": storagePath,
            "gps_count": outcome.rawGPS.count,
            "imu_count": outcome.rawIMU.count,
            "byte_size": blob.byteSize,
            "sha256": blob.sha256,
        ])

        // 4. Fast-path authoritative scoring (the queue sweep is the retry net).
        let scored = try await api.invokeScoreRun(runId: runId)
        return try JSONDecoder().decode(AuthoritativeResult.self, from: scored)
    }
}
