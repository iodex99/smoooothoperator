import SOCore
import SwiftUI

/// Competition first (spec §§14, 53): today's challenge hero, friend
/// challenges, nearby — never an analytics dashboard.
struct HomeView: View {
    @State private var model = HomeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack(alignment: .top) {
                        Wordmark()
                        Spacer()
                        Image(systemName: "bell")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(SOTheme.textSecondary)
                            .frame(width: 40, height: 40)
                            .background(SOTheme.surface, in: Circle())
                            .overlay(Circle().strokeBorder(SOTheme.hairline, lineWidth: 1))
                    }
                    .padding(.top, 8)

                    if let challenge = model.todaysChallenge {
                        TodaysChallengeCard(challenge: challenge)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 260)
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
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(SOTheme.ground)
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.load() }
        }
    }
}

/// The hero: route trace burning across a dark card, one unmissable CTA.
struct TodaysChallengeCard: View {
    let challenge: HomeModel.Challenge

    var body: some View {
        NavigationLink {
            CourseDetailView(courseId: challenge.courseId)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("TODAY'S CHALLENGE")
                        .font(.caption.weight(.black))
                        .tracking(1.6)
                        .foregroundStyle(SOTheme.heatStart)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SOTheme.heatStart.opacity(0.13), in: Capsule())
                    Spacer()
                    Text(String(repeating: "★", count: challenge.difficulty))
                        .font(.subheadline)
                        .foregroundStyle(SOTheme.heatEnd)
                }

                if let route = challenge.route {
                    RoutePreview(route: route)
                        .frame(height: 128)
                }

                Text(challenge.name)
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    SOChip(icon: "road.lanes", text: challenge.distanceText)
                    SOChip(icon: "arrow.triangle.turn.up.right.diamond", text: "\(challenge.turnCount) turns")
                    Spacer()
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("YOUR BEST")
                            .font(.caption2.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(SOTheme.textSecondary)
                        Text(challenge.yourBest.map(String.init) ?? "—")
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("DRIVE")
                        .font(.system(.headline, design: .rounded).weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 14)
                        .background(SOTheme.heat, in: Capsule())
                        .shadow(color: SOTheme.heatStart.opacity(0.5), radius: 14, y: 5)
                }
            }
            .padding(18)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(SOTheme.surface)
                    RadialGradient(
                        colors: [SOTheme.heatStart.opacity(0.16), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(SOTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct FriendChallengeRow: View {
    let challenge: HomeModel.FriendChallenge

    var body: some View {
        HStack(spacing: 14) {
            Text(String(challenge.friendName.prefix(1)).uppercased())
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(SOTheme.heatEnd)
                .frame(width: 42, height: 42)
                .background(SOTheme.heatStart.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(challenge.friendName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\u{201C}Beat my \(challenge.score)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(SOTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(SOTheme.textSecondary)
        }
        .soCard(padding: 14)
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
        var turnCount: Int
        var yourBest: Int?
        var route: [GeoCoordinate]?
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
        var route: [GeoCoordinate]?
        #if DEBUG
        route = DemoCourse.route
        #endif
        todaysChallenge = Challenge(
            courseId: "demo",
            name: "Malibu #042",
            distanceText: Measurement(value: 20.6, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated)),
            difficulty: 4,
            turnCount: 23,
            yourBest: nil,
            route: route
        )
    }
}
