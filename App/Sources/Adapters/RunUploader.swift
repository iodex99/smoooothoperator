import CryptoKit
import Foundation
import SOSync
import SOTelemetry

/// Uploads a finished run: compact telemetry blob → storage, runs row +
/// envelope → REST, then invokes score-run for the authoritative result
/// (spec §§46, 60). A completed run must never be lost: failures leave the
/// run in the local retry queue (UploadState machine).
struct RunUploader {
    let api: SupabaseAPI

    struct AuthoritativeResult: Decodable {
        var verdict: String
        var score: Int
        var finished: Bool
    }

    /// Same compact wire format score-run parses ([-9999] = nil sentinel).
    static func telemetryPayload(outcome: DriveRunOutcome) throws -> Data {
        let absent = -9999.0
        let payload: [String: Any] = [
            "formatVersion": 1,
            "gps": outcome.rawGPS.map { sample in
                [sample.timestamp,
                 sample.coordinate.latitude,
                 sample.coordinate.longitude,
                 sample.horizontalAccuracy,
                 sample.course ?? absent,
                 sample.speed ?? absent,
                 sample.altitude ?? absent]
            },
            "imu": outcome.rawIMU.map { sample in
                [sample.timestamp,
                 sample.accelX, sample.accelY, sample.accelZ,
                 sample.gyroX, sample.gyroY, sample.gyroZ]
            },
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func upload(
        outcome: DriveRunOutcome,
        courseId: String,
        vehicleId: String? = nil
    ) async throws -> AuthoritativeResult {
        guard let userId = await api.userId else { throw SupabaseAPI.APIError.notAuthenticated }

        let blob = try Self.telemetryPayload(outcome: outcome)
        let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let runStart = outcome.rawGPS.first?.timestamp ?? Date().timeIntervalSince1970

        // 1. Blob first — the run row only exists once its data is safe.
        let storagePath = "\(userId)/\(UUID().uuidString.lowercased()).json"
        try await api.uploadTelemetry(path: storagePath, data: blob)

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
            "byte_size": blob.count,
            "sha256": digest,
        ])

        // 4. Fast-path authoritative scoring (the queue sweep is the retry net).
        let scored = try await api.invokeScoreRun(runId: runId)
        return try JSONDecoder().decode(AuthoritativeResult.self, from: scored)
    }
}
