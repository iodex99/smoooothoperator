import SwiftUI

/// Driver identity (spec §§13, 30, 95): rating, records, achievements,
/// and the App Store-required account controls.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Text("SMOOOOTH RATING")
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                        Text("—")
                            .font(.system(size: 56, weight: .black, design: .rounded))
                        Text("UNRANKED")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Records") {
                    LabeledContent("Verified runs", value: "0")
                    LabeledContent("Wins", value: "0")
                    LabeledContent("Top 10 finishes", value: "0")
                }

                Section("Friends") {
                    NavigationLink("Friends") { FriendsView() }
                }

                Section("Smooooth Pro") {
                    Button("Upgrade to Pro") { showPaywall = true }
                    Button("Restore purchases") {
                        Task { try? await environment.subscriptions.restore() }
                    }
                }

                Section("Account") {
                    NavigationLink("Privacy") { PrivacySettingsView() }
                    Link("Support", destination: URL(string: "https://smooooth.app/support")!)
                    Button("Delete account", role: .destructive) {
                        // Account + telemetry deletion flow (spec §62) —
                        // server endpoint wired at device stage.
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }
}

/// Ghost + location privacy controls (spec §§35, 62, 70).
struct PrivacySettingsView: View {
    @AppStorage("ghostVisibility") private var ghostVisibility = "everyone"

    var body: some View {
        List {
            Section {
                Picker("Who can race my ghost", selection: $ghostVisibility) {
                    Text("Anyone").tag("everyone")
                    Text("Friends").tag("friends")
                    Text("Nobody").tag("nobody")
                }
            } footer: {
                Text("Ghosts share only your pace along the course — never your raw location.")
            }
        }
        .navigationTitle("Privacy")
    }
}
