import SwiftUI

/// Four tabs, nothing more (spec §13). Dark mode is the primary experience.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

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
    }
}

/// First-use safety gate (spec §77) — required acknowledgement.
struct SafetyAcknowledgementView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DRIVE SAFE")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                .tracking(1.5)

            VStack(alignment: .leading, spacing: 12) {
                SafetyRule(text: "Never interact with Smooooth Operator while driving.")
                SafetyRule(text: "Mount your phone before starting.")
                SafetyRule(text: "Follow all traffic laws.")
                SafetyRule(text: "Do not speed or drive aggressively to improve your score.")
                SafetyRule(text: "The goal is smooth, controlled driving.")
            }

            Spacer()

            Button {
                environment.hasAcknowledgedSafety = true
            } label: {
                Text("I understand")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.large])
    }
}

private struct SafetyRule: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.body)
        }
    }
}
