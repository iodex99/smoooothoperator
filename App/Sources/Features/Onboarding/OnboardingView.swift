import SOCore
import SwiftUI

/// First-run onboarding (spec §§76-77): what the game is, how scoring
/// works, why runs are verified, then the mandatory safety gate. Five
/// pages, driver-paced, ends in the app. Runs once; the safety
/// acknowledgement is stored with it.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var environment
    var demoAutoAdvance = false

    @State private var page = 0
    private static let pageCount = 6
    private static let locationPage = 5

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            RadialGradient(
                colors: [SOTheme.heatStart.opacity(0.10), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    GamePage().tag(1)
                    ScorePage().tag(2)
                    VerifiedPage().tag(3)
                    SafetyPage().tag(4)
                    LocationPage().tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)

                HStack(spacing: 7) {
                    ForEach(0..<Self.pageCount, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? AnyShapeStyle(SOTheme.heat) : AnyShapeStyle(SOTheme.elevated))
                            .frame(width: index == page ? 22 : 7, height: 7)
                    }
                }
                .padding(.bottom, 18)

                VStack(spacing: 10) {
                    Button(primaryTitle) {
                        advance()
                    }
                    .buttonStyle(HeatButtonStyle())

                    // Location is genuinely optional: the app still drives,
                    // scores and queues without it. Never trap a driver on
                    // a permission screen.
                    if page == Self.locationPage {
                        Button("Not now") { environment.completeOnboarding() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard demoAutoAdvance else { return }
            // CI capture: walk the pages, never complete (screenshots stop
            // at the last page).
            for next in 1..<Self.pageCount {
                try? await Task.sleep(for: Self.demoPageDwell)
                page = next
            }
        }
    }

    /// How long each page stays up in CI capture mode.
    ///
    /// COUPLED TO THE CAPTURE CADENCE IN ios-nightly.yml, which photographs
    /// the onboarding walk roughly every two seconds. This was four seconds
    /// and it aliased: a page could be caught once, or stepped over
    /// entirely. Runs on 2026-08-19 and -20 each lost a different page, one
    /// of them the safety gate, and nothing failed — the tooling downstream
    /// cannot tell a page seen once from an animation frame.
    ///
    /// Eight seconds is four captures per page. The tour uses twelve for the
    /// same three-to-four captures, because its loop sleeps between shots
    /// and this one does not; the captures matter, not the seconds.
    static let demoPageDwell = Duration.seconds(8)

    private var locationDenied: Bool {
        environment.sensors.authorizationStatus == .denied
            || environment.sensors.authorizationStatus == .restricted
    }

    private var locationGranted: Bool {
        environment.sensors.authorizationStatus == .authorizedWhenInUse
            || environment.sensors.authorizationStatus == .authorizedAlways
    }

    private var primaryTitle: String {
        switch page {
        case Self.pageCount - 2: "I UNDERSTAND"
        case Self.locationPage:
            locationGranted ? "START DRIVING" : (locationDenied ? "OPEN SETTINGS" : "TURN ON LOCATION")
        default: "CONTINUE"
        }
    }

    private func advance() {
        guard page == Self.locationPage else {
            page += 1
            return
        }
        if locationGranted {
            environment.completeOnboarding()
            return
        }
        if locationDenied {
            // Once denied, the system prompt never appears again — Settings
            // is the only route, so say so instead of showing a dead button.
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            #endif
            return
        }
        environment.sensors.requestPermissions()
        // The system prompt is asynchronous. Give it a beat, then let the
        // driver into the app either way — the answer is theirs to make.
        Task {
            try? await Task.sleep(for: .seconds(2))
            environment.completeOnboarding()
        }
    }
}

#if DEBUG
/// CI capture mode for the onboarding flow (SMOOOOTH_DEMO_ONBOARDING=1).
enum OnboardingDemo {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SMOOOOTH_DEMO_ONBOARDING"] == "1"
    }
}
#endif

// MARK: - Pages

private struct WelcomePage: View {
    /// A stylized course shape for the hero trace — pure decoration.
    private static let heroRoute: [GeoCoordinate] = [
        .init(latitude: 0.00, longitude: 0.00),
        .init(latitude: 0.05, longitude: 0.09),
        .init(latitude: 0.03, longitude: 0.20),
        .init(latitude: 0.11, longitude: 0.26),
        .init(latitude: 0.18, longitude: 0.22),
        .init(latitude: 0.16, longitude: 0.34),
        .init(latitude: 0.25, longitude: 0.42),
        .init(latitude: 0.35, longitude: 0.38),
        .init(latitude: 0.33, longitude: 0.52),
        .init(latitude: 0.44, longitude: 0.60),
    ]

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Wordmark()
            RoutePreview(route: Self.heroRoute, lineWidth: 4)
                .frame(height: 170)
                .padding(.horizontal, 30)
            VStack(spacing: 8) {
                Text("Real roads. Driven smooth.")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                Text("Compete on real courses. The best drive is fast, smooth, controlled — and legal.")
                    .font(.subheadline)
                    .foregroundStyle(SOTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            Spacer()
        }
    }
}

private struct GamePage: View {
    var body: some View {
        OnboardPage(
            icon: "flag.checkered.2.crossed",
            title: "Pick a course.\nBeat the benchmark.",
            rows: [
                ("point.topleft.down.curvedto.point.bottomright.up", "Courses are real road routes with a start and a finish gate."),
                ("timer", "Every course has a benchmark time. Match it — smoothly — for a perfect pace score."),
                ("figure.wave", "Race friends' ghosts and climb the boards."),
            ]
        )
    }
}

private struct ScorePage: View {
    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Text("One score.\nFour disciplines.")
                .font(.system(.title, design: .rounded).weight(.black))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            VStack(spacing: 16) {
                WeightRow(label: "Pace", weight: 0.35)
                WeightRow(label: "Smoothness", weight: 0.35)
                WeightRow(label: "Control", weight: 0.20)
                WeightRow(label: "Legal", weight: 0.10)
            }
            .soCard(padding: 20)
            .padding(.horizontal, 24)
            Text("Fast alone doesn't win.")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(SOTheme.heat)
            Spacer()
        }
    }
}

private struct WeightRow: View {
    let label: String
    let weight: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(SOTheme.textSecondary)
                .frame(width: 104, alignment: .leading)
            HeatBar(progress: weight)
            Text("\(Int(weight * 100))%")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct VerifiedPage: View {
    var body: some View {
        OnboardPage(
            icon: "checkmark.shield.fill",
            title: "Every run\nis verified.",
            rows: [
                ("cpu", "The server re-scores every run and checks the physics. Impossible drives never rank."),
                ("location.slash", "Mock GPS and tampered sensors are detected — quietly marked, never ranked."),
                ("lock", "Your location is recorded only during a challenge. Ghosts share pace, never raw location."),
            ]
        )
    }
}

private struct SafetyPage: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                GlowRing(progress: 1, lineWidth: 5)
                    .frame(width: 84, height: 84)
                Image(systemName: "shield.fill")
                    .font(.system(.title))
                    .foregroundStyle(SOTheme.heat)
            }
            VStack(spacing: 4) {
                Text("DRIVE SAFE")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("Smooth wins. Reckless never does.")
                    .font(.subheadline)
                    .foregroundStyle(SOTheme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 13) {
                OnboardRule(text: "Never interact with Smooooth Operator while driving.")
                OnboardRule(text: "Mount your phone before starting.")
                OnboardRule(text: "Follow all traffic laws.")
                OnboardRule(text: "Do not speed or drive aggressively to improve your score.")
                OnboardRule(text: "The goal is smooth, controlled driving.")
            }
            .soCard(padding: 18)
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

/// Asked last, once the driver knows what the app is for. A run cannot
/// start without location anyway, and Explore has nothing to show until it
/// knows where "near you" is — so asking here saves a dead-end first launch.
private struct LocationPage: View {
    @Environment(AppEnvironment.self) private var environment

    private var granted: Bool {
        environment.sensors.authorizationStatus == .authorizedWhenInUse
            || environment.sensors.authorizationStatus == .authorizedAlways
    }

    private var denied: Bool {
        environment.sensors.authorizationStatus == .denied
            || environment.sensors.authorizationStatus == .restricted
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                GlowRing(progress: 1, lineWidth: 5)
                    .frame(width: 84, height: 84)
                Image(systemName: granted ? "location.fill" : "location")
                    .font(.system(.title))
                    .foregroundStyle(granted ? AnyShapeStyle(SOTheme.verified) : AnyShapeStyle(SOTheme.heat))
            }
            VStack(spacing: 6) {
                Text(granted ? "You're set" : "Find the roads near you")
                    .font(.system(.title, design: .rounded).weight(.black))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(granted
                     ? "Courses around you are loading."
                     : "Smooooth Operator measures a drive on a real road, so it needs your location to find courses near you — and to time the run at all.")
                    .font(.subheadline)
                    .foregroundStyle(SOTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
            }
            // Deliberately NOT OnboardRule: those carry a green verified
            // shield because each line is a commitment being acknowledged.
            // These are statements of fact about how location is used, and
            // green in this app means verification, never emphasis.
            VStack(alignment: .leading, spacing: 13) {
                LocationFact(icon: "location.circle", text: "Used while you drive, and to list courses near you.")
                LocationFact(icon: "moon.circle", text: "Tracked in the background only during an active run.")
                LocationFact(icon: "eye.slash.circle", text: "Your precise route is never shown to other drivers.")
            }
            .soCard(padding: 18)
            .padding(.horizontal, 24)

            if denied {
                Text("Location is off. Turn it on in Settings whenever you want courses near you.")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.caution)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
        }
    }
}

// MARK: - Shared page scaffolding

private struct OnboardPage: View {
    let icon: String
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack {
                GlowRing(progress: 1, lineWidth: 5)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(.title))
                    .foregroundStyle(SOTheme.heat)
            }
            Text(title)
                .font(.system(.title, design: .rounded).weight(.black))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows, id: \.1) { row in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: row.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SOTheme.heatStart)
                            .frame(width: 30, height: 30)
                            .background(SOTheme.heatStart.opacity(0.12), in: Circle())
                        Text(row.1)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 34)
            Spacer()
        }
    }
}

private struct LocationFact: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SOTheme.heatStart)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardRule: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(SOTheme.verified)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
