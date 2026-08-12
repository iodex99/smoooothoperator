import SwiftUI

/// Competition first (spec §§14, 53): today's challenge hero, friend
/// challenges, nearby — never an analytics dashboard.
struct HomeView: View {
    @State private var model = HomeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let challenge = model.todaysChallenge {
                        TodaysChallengeCard(challenge: challenge)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }

                    SectionHeader(title: "Friend challenges")
                    if model.friendChallenges.isEmpty {
                        EmptyHint(
                            icon: "person.2",
                            text: "Challenge a friend and their dares show up here."
                        )
                    } else {
                        ForEach(model.friendChallenges) { challenge in
                            FriendChallengeRow(challenge: challenge)
                        }
                    }

                    SectionHeader(title: "Nearby challenges")
                    EmptyHint(
                        icon: "location",
                        text: "Courses near you appear once location is allowed."
                    )
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("SMOOOOTH")
            .task { await model.load() }
        }
    }
}

struct TodaysChallengeCard: View {
    let challenge: HomeModel.Challenge

    var body: some View {
        NavigationLink {
            CourseDetailView(courseId: challenge.courseId)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text("TODAY'S CHALLENGE")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(challenge.name)
                    .font(.title2.weight(.heavy))
                HStack(spacing: 14) {
                    Label(challenge.distanceText, systemImage: "road.lanes")
                    Label(String(repeating: "★", count: challenge.difficulty), systemImage: "gauge.high")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack {
                    if let best = challenge.yourBest {
                        VStack(alignment: .leading) {
                            Text("Your best").font(.caption).foregroundStyle(.secondary)
                            Text("\(best)").font(.headline.monospacedDigit())
                        }
                    }
                    Spacer()
                    Text("DRIVE")
                        .font(.headline.weight(.heavy))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
            .padding(18)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}

struct FriendChallengeRow: View {
    let challenge: HomeModel.FriendChallenge

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(challenge.friendName).font(.headline)
                Text("\u{201C}Beat my \(challenge.score)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
@Observable
final class HomeModel {
    struct Challenge: Identifiable {
        var id: String { courseId }
        var courseId: String
        var name: String
        var distanceText: String
        var difficulty: Int
        var yourBest: Int?
    }

    struct FriendChallenge: Identifiable {
        var id: String
        var friendName: String
        var score: Int
    }

    var todaysChallenge: Challenge?
    var friendChallenges: [FriendChallenge] = []

    func load() async {
        // Server-driven home feed lands with the API wiring on device;
        // placeholder keeps the screen structurally real.
        todaysChallenge = Challenge(
            courseId: "demo",
            name: "Malibu #042",
            distanceText: Measurement(value: 20.6, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated)),
            difficulty: 4,
            yourBest: nil
        )
    }
}
