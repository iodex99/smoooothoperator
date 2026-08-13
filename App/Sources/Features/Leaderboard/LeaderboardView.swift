import SwiftUI

/// Global / country / friends boards (spec §47).
///
/// A leaderboard is only meaningful FOR A COURSE: `rank` is computed per
/// course, so an unfiltered query returns every course's #1 side by side,
/// all reading "1". The board therefore always targets one course — today's
/// challenge by default — and says which one.
struct LeaderboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var scope: Scope = .global
    @State private var state: LoadState = .loading
    @State private var courseId: String?
    @State private var courseName = ""

    enum Scope: String, CaseIterable, Identifiable {
        case global = "Global"
        case country = "Country"
        case friends = "Friends"

        var id: String { rawValue }
    }

    enum LoadState {
        case loading
        case ready([Entry])
        case failed(String)
    }

    struct Entry: Identifiable, Decodable {
        var id: String { "\(rank)-\(username)" }
        var rank: Int
        var username: String
        var score: Int
        var durationSeconds: Double

        enum CodingKeys: String, CodingKey {
            case rank, username, score
            case durationSeconds = "duration_seconds"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !courseName.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                .font(.caption2)
                            Text(courseName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(SOTheme.textSecondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(Scope.allCases) { item in
                            SelectableChip(
                                label: item.rawValue,
                                selected: scope == item
                            ) { scope = item }
                        }
                        Spacer()
                    }

                    switch state {
                    case .loading:
                        ProgressView()
                            .tint(SOTheme.heatStart)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    case .ready(let entries) where entries.isEmpty:
                        emptyBoard
                    case .ready(let entries):
                        ForEach(entries) { entry in
                            LeaderboardRow(entry: entry)
                        }
                    case .failed(let message):
                        VStack(spacing: 14) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.largeTitle)
                                .foregroundStyle(SOTheme.caution)
                            // Never claim "no runs yet" when we simply failed
                            // to ask — that is a statement about the world.
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(SOTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(GhostButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    }
                }
                .padding(18)
            }
            .background(SOTheme.ground)
            .navigationTitle("Leaderboards")
            .refreshable { await load() }
            // Re-queries when the scope chip changes — the chips used to be
            // decorative and every scope showed identical rows.
            .task(id: scope) { await load() }
        }
    }

    private var emptyBoard: some View {
        VStack(spacing: 16) {
            ZStack {
                GlowRing(progress: 1, lineWidth: 5)
                    .frame(width: 92, height: 92)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(SOTheme.heat)
            }
            .accessibilityHidden(true)
            Text(scope == .global ? "No verified runs yet" : "Nobody here yet")
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
            Text(scope == .friends
                ? "Add friends and their verified runs show up here."
                : "Drive this course — verified runs rank here.\nQuestionable runs never do.")
                .font(.subheadline)
                .foregroundStyle(SOTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private func load() async {
        guard let api = environment.api, await api.userId != nil else {
            state = .failed("Sign in to see how you rank.")
            return
        }
        do {
            let course = try await resolveCourse(api: api)
            guard let course else {
                state = .failed("No challenge course yet — drive one and the board opens up.")
                return
            }
            var query = "course_leaderboards?course_id=eq.\(course)"
                + "&select=rank,username,score,duration_seconds&order=rank&limit=100"
            switch scope {
            case .global:
                break
            case .country:
                if let country = try await myCountry(api: api) {
                    query += "&country=eq.\(country)"
                } else {
                    state = .failed("Add your country in Profile to see your national board.")
                    return
                }
            case .friends:
                let ids = try await friendIds(api: api)
                guard !ids.isEmpty else {
                    state = .ready([])
                    return
                }
                query += "&user_id=in.(\(ids.joined(separator: ",")))"
            }
            state = .ready(try await api.get(query, as: [Entry].self))
        } catch {
            state = .failed("Couldn't load the board. Check your connection and try again.")
        }
    }

    /// Today's challenge course is the board everyone is actually competing
    /// on; the server has already picked and cached it for this user/day.
    private func resolveCourse(api: SupabaseAPI) async throws -> String? {
        if let courseId { return courseId }
        let data = try await api.invokeTodayChallenge(
            latitude: LastKnownLocation.coordinate()?.latitude,
            longitude: LastKnownLocation.coordinate()?.longitude,
            timezone: TimeZone.current.identifier
        )
        let payload = try JSONDecoder().decode(TodayChallengePayload.self, from: data)
        courseId = payload.course?.id
        courseName = payload.course?.name ?? ""
        return courseId
    }

    private func myCountry(api: SupabaseAPI) async throws -> String? {
        struct Row: Decodable { var country: String? }
        guard let id = await api.userId else { return nil }
        let rows = try await api.get("profiles?id=eq.\(id)&select=country", as: [Row].self)
        return rows.first?.country
    }

    private func friendIds(api: SupabaseAPI) async throws -> [String] {
        struct Row: Decodable {
            var requester_id: String
            var addressee_id: String
        }
        guard let me = await api.userId else { return [] }
        let rows = try await api.get(
            "friendships?status=eq.accepted&select=requester_id,addressee_id",
            as: [Row].self
        )
        return rows.map { $0.requester_id == me ? $0.addressee_id : $0.requester_id } + [me]
    }
}

struct LeaderboardRow: View {
    let entry: LeaderboardView.Entry

    var body: some View {
        HStack(spacing: 14) {
            RankBadge(rank: entry.rank)
            Text(entry.username)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.score)")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(Duration.seconds(entry.durationSeconds)
                    .formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SOTheme.textSecondary)
            }
        }
        .soCard(padding: 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Rank \(entry.rank), \(entry.username), \(entry.score) points"
        )
    }
}

/// Top three get medal treatment; everyone else a quiet number.
struct RankBadge: View {
    let rank: Int

    var body: some View {
        Group {
            if rank <= 3 {
                Text("\(rank)")
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(medal, in: Circle())
                    .shadow(color: medalGlow.opacity(0.5), radius: 6)
            } else {
                Text("\(rank)")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SOTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(SOTheme.elevated, in: Circle())
            }
        }
    }

    private var medal: LinearGradient {
        let colors: [Color] = switch rank {
        case 1: [Color(red: 1.0, green: 0.84, blue: 0.35), Color(red: 0.93, green: 0.65, blue: 0.13)]
        case 2: [Color(red: 0.85, green: 0.87, blue: 0.91), Color(red: 0.63, green: 0.66, blue: 0.72)]
        default: [Color(red: 0.87, green: 0.58, blue: 0.33), Color(red: 0.68, green: 0.42, blue: 0.20)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var medalGlow: Color {
        switch rank {
        case 1: Color(red: 1.0, green: 0.84, blue: 0.35)
        case 2: Color(red: 0.85, green: 0.87, blue: 0.91)
        default: Color(red: 0.87, green: 0.58, blue: 0.33)
        }
    }
}
