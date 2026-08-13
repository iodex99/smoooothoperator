import SwiftUI

/// Driver identity (spec §§13, 30, 95): rating, records, achievements,
/// and the App Store-required account controls.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Rating hero — fills with verified runs.
                    VStack(spacing: 12) {
                        ZStack {
                            GlowRing(progress: 0, lineWidth: 11)
                                .frame(width: 168, height: 168)
                            VStack(spacing: 2) {
                                Text("—")
                                    .font(.system(size: 52, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                Text("UNRANKED")
                                    .font(.caption2.weight(.black))
                                    .tracking(1.6)
                                    .foregroundStyle(SOTheme.textSecondary)
                            }
                        }
                        Text("SMOOOOTH RATING")
                            .font(.caption.weight(.black))
                            .tracking(2)
                            .foregroundStyle(SOTheme.heatStart)
                        Text("Drive verified runs to earn your rating.")
                            .font(.footnote)
                            .foregroundStyle(SOTheme.textSecondary)
                    }
                    .padding(.top, 10)

                    HStack(spacing: 10) {
                        StatTile(label: "Verified runs", value: "0")
                        StatTile(label: "Wins", value: "0")
                        StatTile(label: "Top 10", value: "0")
                    }

                    NavigationLink {
                        FriendsView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "person.2.fill")
                                .foregroundStyle(SOTheme.heatStart)
                                .frame(width: 40, height: 40)
                                .background(SOTheme.heatStart.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Friends")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Rivals make you smoother.")
                                    .font(.caption)
                                    .foregroundStyle(SOTheme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SOTheme.textSecondary)
                        }
                        .soCard(padding: 14)
                    }
                    .buttonStyle(.plain)

                    // Pro upsell card.
                    Button {
                        showPaywall = true
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SMOOOOTH PRO")
                                    .font(.system(.headline, design: .rounded).weight(.black))
                                    .tracking(1)
                                    .foregroundStyle(.black)
                                Text("Ghost racing · custom courses · analytics")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.black.opacity(0.7))
                            }
                            Spacer()
                            Image(systemName: "bolt.fill")
                                .font(.title2)
                                .foregroundStyle(.black)
                        }
                        .padding(18)
                        .background(SOTheme.heat, in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: SOTheme.heatStart.opacity(0.4), radius: 14, y: 5)
                    }
                    .buttonStyle(.plain)

                    // Account section (App Store-required controls).
                    VStack(spacing: 0) {
                        NavigationLink {
                            PrivacySettingsView()
                        } label: {
                            AccountRow(icon: "hand.raised", title: "Privacy", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        Link(destination: URL(string: "https://smooooth.app/support")!) {
                            AccountRow(icon: "questionmark.circle", title: "Support", showsChevron: true)
                        }
                        Divider().overlay(SOTheme.hairline)
                        Button {
                            Task { try? await environment.subscriptions.restore() }
                        } label: {
                            AccountRow(icon: "arrow.clockwise", title: "Restore purchases", showsChevron: false)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        Button(role: .destructive) {
                            // Account + telemetry deletion flow (spec §62) —
                            // server endpoint wired at device stage.
                        } label: {
                            AccountRow(
                                icon: "trash",
                                title: "Delete account",
                                showsChevron: false,
                                tint: SOTheme.danger
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .background(SOTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(SOTheme.hairline, lineWidth: 1)
                    )
                }
                .padding(18)
            }
            .background(SOTheme.ground)
            .navigationTitle("Profile")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }
}

struct AccountRow: View {
    let icon: String
    let title: String
    var showsChevron: Bool
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint == .white ? SOTheme.textSecondary : tint)
                .frame(width: 24)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            Spacer()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SOTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
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
                .listRowBackground(SOTheme.surface)
            } footer: {
                Text("Ghosts share only your pace along the course — never your raw location.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SOTheme.ground)
        .navigationTitle("Privacy")
    }
}
