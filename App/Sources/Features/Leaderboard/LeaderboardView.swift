import SwiftUI

/// Global / country / friends boards (spec §47). Rows show rank, driver,
/// score, time, verified status.
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
            List {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if entries.isEmpty {
                    ContentUnavailableView(
                        "No verified runs yet",
                        systemImage: "trophy",
                        description: Text("Drive a course — verified runs rank here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        HStack {
                            Text("#\(entry.rank)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 44, alignment: .leading)
                            Text(entry.username)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(entry.score)").font(.headline.monospacedDigit())
                                Text(Duration.seconds(entry.durationSeconds)
                                    .formatted(.time(pattern: .minuteSecond)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
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
