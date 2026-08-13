import SOCore
import SOCourse
import SwiftUI

/// Competition first (spec §§14, 53): today's challenge hero, friend
/// challenges, nearby — never an analytics dashboard. The hero is assigned
/// dynamically by the server from courses near the user (directive
/// 2026-08-13); the client just asks and renders.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
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

                    switch model.state {
                    case .loading:
                        ProgressView()
                            .tint(SOTheme.heatStart)
                            .frame(maxWidth: .infinity, minHeight: 260)
                    case .ready(let challenge):
                        TodaysChallengeCard(challenge: challenge)
                    case .empty(let message, let needsLocation):
                        ChallengeEmptyCard(
                            message: message,
                            needsLocation: needsLocation,
                            onGranted: { Task { await model.load(api: environment.api) } }
                        )
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
            .task { await model.load(api: environment.api) }
            .refreshable { await model.load(api: environment.api) }
        }
    }
}

/// The hero: route trace burning across a dark card, one unmissable CTA.
struct TodaysChallengeCard: View {
    let challenge: HomeModel.Challenge

    var body: some View {
        NavigationLink {
            CourseDetailView(courseId: challenge.courseId, preloaded: challenge.detail)
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

                VStack(alignment: .leading, spacing: 1) {
                    Text(challenge.formatTitle.uppercased())
                        .font(.system(.subheadline, design: .rounded).weight(.black))
                        .tracking(1.2)
                        .foregroundStyle(SOTheme.heat)
                    Text(challenge.tagline)
                        .font(.caption)
                        .foregroundStyle(SOTheme.textSecondary)
                }

                if let route = challenge.route {
                    RoutePreview(route: route)
                        .frame(height: 118)
                }

                Text(challenge.name)
                    .font(.system(size: 27, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    SOChip(icon: "road.lanes", text: challenge.distanceText)
                    if let duration = challenge.durationText {
                        SOChip(icon: "timer", text: duration)
                    }
                    if challenge.participantsToday > 0 {
                        SOChip(icon: "person.2", text: "\(challenge.participantsToday) today")
                    }
                    Spacer()
                }

                HStack(alignment: .center) {
                    if challenge.firstRecord {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FIRST RECORD")
                                .font(.caption2.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(SOTheme.textSecondary)
                            Text("Set the benchmark")
                                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                                .foregroundStyle(SOTheme.verified)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("YOUR BEST")
                                .font(.caption2.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(SOTheme.textSecondary)
                            Text(challenge.yourBest.map { "\($0)" } ?? "—")
                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        if let friend = challenge.friendBest {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.username.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .tracking(1)
                                    .foregroundStyle(SOTheme.textSecondary)
                                Text("\(friend.score)")
                                    .font(.system(.title3, design: .rounded).weight(.heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(SOTheme.heatEnd)
                            }
                            .padding(.leading, 18)
                        }
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

/// Honest no-challenge states (directive §§20-21): coming-soon areas and
/// missing location — never a fabricated challenge.
///
/// When the blocker is permission, this card must be able to FIX it. It
/// previously said "Allow location and Today's Challenge finds your local
/// course" with no button anywhere — a new user's hardest dead end.
struct ChallengeEmptyCard: View {
    @Environment(AppEnvironment.self) private var environment
    let message: String
    var needsLocation = false
    var onGranted: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                GlowRing(progress: 1, lineWidth: 5)
                    .frame(width: 74, height: 74)
                Image(systemName: "flag.checkered")
                    .font(.system(size: 26))
                    .foregroundStyle(SOTheme.heat)
            }
            Text("TODAY'S CHALLENGE")
                .font(.caption.weight(.black))
                .tracking(1.6)
                .foregroundStyle(SOTheme.heatStart)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(SOTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if needsLocation {
                Button("Allow location") {
                    environment.sensors.requestPermissions()
                    // The prompt is async; re-ask shortly after so the card
                    // becomes the challenge without needing a manual refresh.
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        onGranted()
                    }
                }
                .buttonStyle(HeatButtonStyle())
                .padding(.horizontal, 8)

                Text("Used only during a challenge, never in the background.")
                    .font(.caption2)
                    .foregroundStyle(SOTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
        .background(SOTheme.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(SOTheme.hairline, lineWidth: 1)
        )
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
        var formatTitle: String
        var tagline: String
        var distanceText: String
        var durationText: String?
        var difficulty: Int
        var participantsToday: Int
        var yourBest: Int?
        var friendBest: (score: Int, username: String)?
        var firstRecord: Bool
        var route: [GeoCoordinate]?
        /// Drive-ready handoff for the course screen.
        var detail: CourseDetailModel.Course?
    }

    struct FriendChallenge: Identifiable {
        var id: String
        var friendName: String
        var score: Int
    }

    enum State {
        case loading
        case ready(Challenge)
        /// The Bool marks the one empty state the user can actually resolve.
        case empty(String, needsLocation: Bool)
    }

    var state: State = .loading
    var friendChallenges: [FriendChallenge] = []

    func load(api: SupabaseAPI?) async {
        guard let api else {
            loadDemo()
            return
        }
        do {
            let location = LastKnownLocation.coordinate()
            let data = try await api.invokeTodayChallenge(
                latitude: location?.latitude,
                longitude: location?.longitude,
                timezone: TimeZone.current.identifier
            )
            let payload = try JSONDecoder().decode(TodayChallengePayload.self, from: data)
            apply(payload)
        } catch SupabaseAPI.APIError.notAuthenticated {
            // Pulling to refresh can never fix this; say what will.
            state = .empty("Sign in to get your daily challenge.", needsLocation: false)
        } catch {
            state = .empty("Today's Challenge couldn't load. Pull to retry.", needsLocation: false)
        }
    }

    private func apply(_ payload: TodayChallengePayload) {
        guard payload.state == "ready", let course = payload.course else {
            state = .empty(
                payload.message ?? "Today's Challenge is coming to your area.",
                needsLocation: payload.state == "unavailable"
            )
            return
        }
        // GeoJSON order is [lon, lat].
        let route = course.polyline.compactMap { pair -> GeoCoordinate? in
            guard pair.count >= 2 else { return nil }
            return GeoCoordinate(latitude: pair[1], longitude: pair[0])
        }
        let gates = course.gates.map {
            Checkpoint(
                sequence: $0.sequence,
                center: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                radiusMeters: $0.radiusMeters
            )
        }
        let durationSeconds = course.estimatedDurationSeconds ?? course.benchmarkSeconds
        state = .ready(Challenge(
            courseId: course.id,
            name: course.name,
            formatTitle: payload.format?.title ?? "Smooth Sprint",
            tagline: payload.format?.tagline ?? "Find your fastest smooth drive.",
            distanceText: Measurement(value: course.distanceMeters, unit: UnitLength.meters)
                .converted(to: .kilometers)
                .formatted(.measurement(width: .abbreviated)),
            durationText: durationSeconds.map { "~\(Int((Double($0) / 60).rounded())) min" },
            difficulty: course.difficulty,
            participantsToday: payload.participantsToday ?? 0,
            yourBest: payload.yourBest,
            friendBest: payload.friendBest.map { ($0.score, $0.username) },
            firstRecord: payload.firstRecord ?? false,
            route: route,
            detail: CourseDetailModel.Course(
                name: course.name,
                polyline: route,
                gates: gates,
                distanceText: Measurement(value: course.distanceMeters, unit: UnitLength.meters)
                    .converted(to: .kilometers)
                    .formatted(.measurement(width: .abbreviated)),
                difficulty: course.difficulty,
                turnCount: course.turnCount,
                drivers: payload.participantsToday ?? 0,
                benchmarkSeconds: course.benchmarkSeconds.map(Double.init)
            )
        ))
    }

    /// Offline/demo mode (no server configured): the bundled demo course,
    /// honestly labeled — no participants, first record open.
    private func loadDemo() {
        var route: [GeoCoordinate]?
        var detail: CourseDetailModel.Course?
        #if DEBUG
        route = DemoCourse.route
        detail = nil // CourseDetailModel resolves "demo" itself
        #endif
        state = .ready(Challenge(
            courseId: "demo",
            name: "Malibu #042",
            formatTitle: "Smooth Sprint",
            tagline: "Find your fastest smooth drive.",
            distanceText: Measurement(value: 4.3, unit: UnitLength.kilometers)
                .formatted(.measurement(width: .abbreviated)),
            durationText: "~5 min",
            difficulty: 4,
            participantsToday: 0,
            yourBest: nil,
            friendBest: nil,
            firstRecord: true,
            route: route,
            detail: detail
        ))
    }
}

/// Wire shape of the today-challenge edge function response.
struct TodayChallengePayload: Decodable {
    var state: String
    var localDate: String?
    var format: Format?
    var course: Course?
    var yourBest: Int?
    var friendBest: FriendBest?
    var participantsToday: Int?
    var firstRecord: Bool?
    var radiusKm: Int?
    var message: String?

    struct Format: Decodable {
        var key: String
        var title: String
        var tagline: String
    }

    struct FriendBest: Decodable {
        var score: Int
        var username: String
    }

    struct Course: Decodable {
        var id: String
        var name: String
        var city: String?
        var country: String?
        var distanceMeters: Double
        var estimatedDurationSeconds: Int?
        var difficulty: Int
        var turnCount: Int
        var benchmarkSeconds: Int?
        var polyline: [[Double]]
        var gates: [Gate]

        struct Gate: Decodable {
            var sequence: Int
            var latitude: Double
            var longitude: Double
            var radiusMeters: Double
        }
    }
}
