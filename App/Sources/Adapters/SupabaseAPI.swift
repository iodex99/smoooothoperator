import Foundation
import SOCore
import SOCourse
import SOGhost
import SOModels
import SOSync
import SOTelemetry

/// Minimal Supabase client (auth + REST + storage + functions) over
/// URLSession — no SDK dependency keeps the surface reviewable and the Kit
/// pure. Endpoints/keys come from configuration, never source (spec §92).
actor SupabaseAPI {
    struct Configuration: Sendable {
        var baseURL: URL
        var anonKey: String

        /// Reads SUPABASE_URL / SUPABASE_ANON_KEY from Info.plist (values
        /// injected per build configuration via xcconfig).
        static func fromBundle() -> Configuration? {
            guard
                let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
                let url = URL(string: urlString),
                let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
            else { return nil }
            return Configuration(baseURL: url, anonKey: key)
        }
    }

    struct Session: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var userId: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case user
        }

        enum UserKeys: String, CodingKey {
            case id
        }

        /// A custom `init(from:)` suppresses the memberwise initializer, and
        /// restoring a stored session needs one.
        init(accessToken: String, refreshToken: String, userId: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.userId = userId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decode(String.self, forKey: .refreshToken)
            let user = try container.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
            userId = try user.decode(String.self, forKey: .id)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(accessToken, forKey: .accessToken)
            try container.encode(refreshToken, forKey: .refreshToken)
        }
    }

    enum APIError: Error {
        case notConfigured
        case notAuthenticated
        case http(Int, String)
    }

    private let configuration: Configuration
    private(set) var session: Session?

    private static let sessionKey = "supabase.session"

    init(configuration: Configuration) {
        self.configuration = configuration
        // A signed-in user stays signed in across launches.
        if let data = KeychainStore.load(key: Self.sessionKey),
           let stored = try? JSONDecoder().decode(StoredSession.self, from: data) {
            session = Session(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                userId: stored.userId
            )
        }
    }

    /// What we keep on the device. Access tokens are short-lived; the
    /// refresh token is the durable credential.
    private struct StoredSession: Codable {
        var accessToken: String
        var refreshToken: String
        var userId: String
    }

    var userId: String? { session?.userId }
    var isSignedIn: Bool { session != nil }

    private func persistSession() {
        guard let session else {
            KeychainStore.delete(key: Self.sessionKey)
            return
        }
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId
        )
        if let data = try? JSONEncoder().encode(stored) {
            KeychainStore.save(data, key: Self.sessionKey)
        }
    }

    /// Exchanges the refresh token for a fresh access token. Supabase access
    /// tokens expire in an hour, so without this every session dies mid-use.
    private func refreshSession() async -> Bool {
        guard let refreshToken = session?.refreshToken else { return false }
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let refreshed = try? JSONDecoder().decode(Session.self, from: data)
        else {
            // The refresh token itself is dead (revoked, or the user deleted
            // the account elsewhere): sign out rather than loop.
            session = nil
            persistSession()
            return false
        }
        session = refreshed
        persistSession()
        return true
    }

    // MARK: - Auth (Sign in with Apple → GoTrue id_token grant)

    func signInWithApple(identityToken: String, nonce: String) async throws {
        let url = configuration.baseURL.appendingPathComponent("auth/v1/token")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": identityToken,
            "nonce": nonce,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureOK(response, data)
        session = try JSONDecoder().decode(Session.self, from: data)
        persistSession()
    }

    func signOut() {
        session = nil
        persistSession()
    }

    // MARK: - REST

    func get<Value: Decodable>(_ path: String, as type: Value.Type) async throws -> Value {
        let data = try await send(path: "rest/v1/\(path)", method: "GET", body: nil)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func insert(_ path: String, json: [String: Any]) async throws -> Data {
        try await send(
            path: "rest/v1/\(path)",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: json),
            headers: ["Prefer": "return=representation"]
        )
    }

    func patch(_ path: String, json: [String: Any]) async throws {
        _ = try await send(
            path: "rest/v1/\(path)",
            method: "PATCH",
            body: try JSONSerialization.data(withJSONObject: json)
        )
    }

    func delete(_ path: String) async throws {
        _ = try await send(path: "rest/v1/\(path)", method: "DELETE", body: nil)
    }

    func rpc(_ name: String, json: [String: Any]) async throws -> Data {
        try await send(
            path: "rest/v1/rpc/\(name)",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: json)
        )
    }

    /// Drive-ready geometry for one course (migration 0013 `course_route`):
    /// GeoJSON polyline + ordered gates, with the server enforcing the same
    /// visibility rules as RLS. Clients never parse WKB.
    func courseRoute(courseId: String) async throws -> (polyline: [GeoCoordinate], gates: [Checkpoint]) {
        struct Payload: Decodable {
            var polyline: [[Double]]
            var gates: [Gate]
            struct Gate: Decodable {
                var sequence: Int
                var latitude: Double
                var longitude: Double
                var radiusMeters: Double
            }
        }
        let data = try await rpc("course_route", json: ["uid": userId ?? "", "cid": courseId])
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        // GeoJSON is [lon, lat].
        let polyline = payload.polyline.compactMap { pair -> GeoCoordinate? in
            guard pair.count >= 2 else { return nil }
            return GeoCoordinate(latitude: pair[1], longitude: pair[0])
        }
        let gates = payload.gates.map {
            Checkpoint(
                sequence: $0.sequence,
                center: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                radiusMeters: $0.radiusMeters
            )
        }
        return (polyline, gates)
    }

    /// The best ghost available to race on a course (spec §§32-36).
    /// RLS decides what "available" means — your own ghosts always, others'
    /// only when their privacy setting allows it — so this cannot leak a
    /// ghost the owner hid.
    func bestGhost(courseId: String) async throws -> (ghost: GhostTrajectory, username: String, score: Int)? {
        struct Row: Decodable {
            var trajectory: GhostTrajectory
            var score: Int
            var profiles: Profile?
            struct Profile: Decodable { var username: String }
        }
        let rows = try await get(
            "ghosts?course_id=eq.\(courseId)&select=trajectory,score,profiles(username)"
                + "&order=score.desc&limit=1",
            as: [Row].self
        )
        guard let row = rows.first, !row.trajectory.points.isEmpty else { return nil }
        return (row.trajectory, row.profiles?.username ?? "a rival", row.score)
    }

    // MARK: - Storage & functions

    func uploadTelemetry(path: String, data: Data) async throws {
        _ = try await send(
            path: "storage/v1/object/telemetry/\(path)",
            method: "POST",
            body: data,
            headers: ["Content-Type": "application/octet-stream"]
        )
    }

    func invokeScoreRun(runId: String) async throws -> Data {
        try await send(
            path: "functions/v1/score-run",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["runId": runId])
        )
    }

    /// Today's Challenge (directive 2026-08-13): the server locates, ranks
    /// and assigns the user's local course for the day.
    func invokeTodayChallenge(
        latitude: Double?,
        longitude: Double?,
        timezone: String
    ) async throws -> Data {
        var body: [String: Any] = ["timezone": timezone]
        if let latitude, let longitude {
            body["latitude"] = latitude
            body["longitude"] = longitude
        }
        return try await send(
            path: "functions/v1/today-challenge",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    // MARK: - Core request

    private func send(
        path: String,
        method: String,
        body: Data?,
        headers: [String: String] = [:]
    ) async throws -> Data {
        do {
            return try await perform(path: path, method: method, body: body, headers: headers)
        } catch APIError.http(401, _) {
            // Expired access token: refresh once, then retry. Anything else
            // propagates — we never loop on auth failures.
            guard await refreshSession() else { throw APIError.notAuthenticated }
            return try await perform(path: path, method: method, body: body, headers: headers)
        }
    }

    private func perform(
        path: String,
        method: String,
        body: Data?,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let token = session?.accessToken else { throw APIError.notAuthenticated }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if request.value(forHTTPHeaderField: "Content-Type") == nil && body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.ensureOK(response, data)
        return data
    }

    private static func ensureOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
