import SOSync
import SwiftUI

/// Four tabs, nothing more (spec §13). Dark mode is the primary experience.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    /// A course opened from a shared link. Presented over whatever tab the
    /// driver was on, so following an invite never loses their place.
    @State private var linkedCourseId: String?
    @State private var linkError: String?

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "flag.checkered") }
            ExploreView()
                .tabItem { Label("Explore", systemImage: "map") }
            LeaderboardView()
                .tabItem { Label("Leaderboards", systemImage: "trophy") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .sheet(isPresented: .constant(!environment.hasAcknowledgedSafety)) {
            SafetyAcknowledgementView()
                .interactiveDismissDisabled()
        }
        // Offered once, after the safety gate, and skippable — the app is
        // fully usable signed out; an account is what makes runs count.
        .sheet(isPresented: Binding(
            get: {
                environment.hasAcknowledgedSafety
                    && !environment.hasSeenSignIn
                    && !environment.isSignedIn
                    && environment.api != nil
            },
            set: { if !$0 { environment.hasSeenSignIn = true } }
        )) {
            SignInView(isOnboardingStep: true)
        }
        // The entitlement has declared applinks since the first iOS commit
        // and nothing read the URL, so every shared challenge opened the app
        // on Home and dropped the code.
        .onOpenURL { url in
            Task { await open(url) }
        }
        .sheet(item: Binding(
            get: { linkedCourseId.map(IdentifiedCourse.init) },
            set: { if $0 == nil { linkedCourseId = nil } }
        )) { linked in
            NavigationStack {
                CourseDetailView(courseId: linked.id)
            }
        }
        .alert(
            linkError ?? "",
            isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
        ) {
            Button("OK") { linkError = nil }
        }
    }

    private func open(_ url: URL) async {
        guard let link = DeepLink(url: url) else {
            // Say so rather than opening Home and looking like nothing
            // happened — the sender believes the link worked.
            linkError = "That link isn't one we recognise."
            return
        }
        switch link {
        case .course(let id):
            linkedCourseId = id
        case .challenge(let code):
            guard let api = environment.api else {
                linkError = "Connect to the internet to open this challenge."
                return
            }
            do {
                // resolve-challenge is anon-safe by design: a shared link has
                // to open for someone who has not installed the app yet.
                let resolved = try await api.resolveChallenge(code: code)
                linkedCourseId = resolved.courseId
            } catch {
                linkError = "That challenge has expired or no longer exists."
            }
        }
    }
}

/// `sheet(item:)` needs an Identifiable; a bare course id is not one.
private struct IdentifiedCourse: Identifiable {
    let id: String
}

/// First-use safety gate (spec §77) — required acknowledgement. The first
/// screen anyone sees: it has to feel like the brand AND mean it.
struct SafetyAcknowledgementView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            RadialGradient(
                colors: [SOTheme.heatStart.opacity(0.13), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Spacer()
                    ZStack {
                        GlowRing(progress: 1, lineWidth: 5)
                            .frame(width: 84, height: 84)
                        Image(systemName: "shield.fill")
                            .font(.system(.title))
                            .foregroundStyle(SOTheme.heat)
                    }
                    Spacer()
                }
                .padding(.top, 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("DRIVE SAFE")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(.white)
                    Text("Smooth wins. Reckless never does.")
                        .font(.subheadline)
                        .foregroundStyle(SOTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SafetyRule(text: "Never interact with Smooooth Operator while driving.")
                    SafetyRule(text: "Mount your phone before starting.")
                    SafetyRule(text: "Follow all traffic laws.")
                    SafetyRule(text: "Do not speed or drive aggressively to improve your score.")
                    SafetyRule(text: "The goal is smooth, controlled driving.")
                }
                .soCard(padding: 18)

                Spacer()

                Button("I UNDERSTAND") {
                    environment.hasAcknowledgedSafety = true
                }
                .buttonStyle(HeatButtonStyle())
            }
            .padding(24)
        }
        .presentationDetents([.large])
    }
}

private struct SafetyRule: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(SOTheme.verified)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
    }
}
