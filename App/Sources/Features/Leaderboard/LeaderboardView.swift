import SwiftUI

/// Global / country / friends boards (spec §47). Rows show rank, driver,
/// score, time — only verified runs ever rank here.
struct LeaderboardView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var scope: Scope = .global
    @State private var entries: [Entry] = []

    enum Scope: String, CaseIterable, Identifiable {
        case global = "Global"
        case country = "Country"
        case friends = "Friends"

        var id: String { rawValue }
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
                    HStack(spacing: 8) {
                        ForEach(Scope.allCases) { item in
                            SelectableChip(
                                label: item.rawValue,
                                selected: scope == item
                            ) { scope = item }
                        }
                        Spacer()
                    }

                    if entries.isEmpty {
                        VStack(spacing: 16) {
                            ZStack {
                                GlowRing(progress: 1, lineWidth: 5)
                                    .frame(width: 92, height: 92)
                                Image(systemName: "trophy.fill")
                                    .font(.system(size: 34))
                                    .foregroundStyle(SOTheme.heat)
                            }
                            Text("No verified runs yet")
                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                .foregroundStyle(.white)
                            Text("Drive a course — verified runs rank here.\nQuestionable runs never do.")
                                .font(.subheadline)
                                .foregroundStyle(SOTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        ForEach(entries) { entry in
                            LeaderboardRow(entry: entry)
                        }
                    }
                }
                .padding(18)
            }
            .background(SOTheme.ground)
            .navigationTitle("Leaderboards")
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = environment.api else { return }
        entries = (try? await api.get(
            "course_leaderboards?select=rank,username,score,duration_seconds&order=rank&limit=100",
            as: [Entry].self
        )) ?? []
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
