import SwiftUI

/// Driver identity (spec §§13, 30, 95): rating, records, achievements,
/// and the App Store-required account controls.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showPaywall = false
    @State private var showSignIn = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var notice: String?
    @State private var stats = ProfileStats()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Rating hero — fills with verified runs.
                    VStack(spacing: 12) {
                        ZStack {
                            GlowRing(
                                progress: Double(stats.rating) / 3_000,
                                lineWidth: 11
                            )
                            .frame(width: 168, height: 168)
                            VStack(spacing: 2) {
                                Text(stats.rating > 0 ? "\(stats.rating)" : "—")
                                    .font(.system(size: 52, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                Text(stats.ratingTier.uppercased())
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

                    if environment.pendingRunCount > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.circle")
                                .foregroundStyle(SOTheme.caution)
                            Text(environment.pendingRunCount == 1
                                ? "1 run saved on this phone, waiting to upload"
                                : "\(environment.pendingRunCount) runs saved on this phone, waiting to upload")
                                .font(.footnote)
                                .foregroundStyle(SOTheme.textSecondary)
                            Spacer()
                        }
                        .soCard(padding: 12)
                    }

                    HStack(spacing: 10) {
                        StatTile(label: "Verified runs", value: "\(stats.verifiedRuns)")
                        StatTile(label: "Wins", value: "\(stats.wins)")
                        StatTile(label: "Top 10", value: "\(stats.topTen)")
                    }

                    NavigationLink {
                        HistoryView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(SOTheme.heatStart)
                                .frame(width: 40, height: 40)
                                .background(SOTheme.heatStart.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your runs")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                Text("Every drive you've recorded.")
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
                                Text("Unlimited challenges · ghost racing")
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
                        if environment.isSignedIn {
                            Button {
                                Task { await environment.signOut() }
                            } label: {
                                AccountRow(
                                    icon: "rectangle.portrait.and.arrow.right",
                                    title: "Sign out",
                                    showsChevron: false
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                showSignIn = true
                            } label: {
                                AccountRow(
                                    icon: "person.badge.shield.checkmark",
                                    title: "Sign in to compete",
                                    showsChevron: true
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().overlay(SOTheme.hairline)
                        NavigationLink {
                            GarageView()
                        } label: {
                            AccountRow(icon: "car.2", title: "Garage", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        NavigationLink {
                            EditProfileView()
                        } label: {
                            AccountRow(icon: "person.text.rectangle", title: "Your profile", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        NavigationLink {
                            AboutView()
                        } label: {
                            AccountRow(icon: "info.circle", title: "About", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        NavigationLink {
                            PrivacySettingsView()
                        } label: {
                            AccountRow(icon: "hand.raised", title: "Privacy", showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(SOTheme.hairline)
                        Link(destination: Brand.support) {
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
                            confirmDelete = true
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
            .sheet(isPresented: $showSignIn) { SignInView() }
            .task(id: environment.isSignedIn) { await loadStats() }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Keep my account", role: .cancel) {}
            } message: {
                Text("This erases your profile, runs, telemetry and friendships. It cannot be undone.")
            }
            .alert(
                notice ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
            ) {
                Button("OK") { notice = nil }
            }
        }
    }

    /// Real records, or honest zeros — never fabricated.
    private func loadStats() async {
        guard let api = environment.api, let id = await api.userId else {
            stats = ProfileStats()
            return
        }
        struct Profile: Decodable {
            var rating: Int
            var rating_tier: String
        }
        struct Entry: Decodable { var rank: Int }
        if let profiles = try? await api.get(
            "profiles?id=eq.\(id)&select=rating,rating_tier", as: [Profile].self
        ), let profile = profiles.first {
            stats.rating = profile.rating
            stats.ratingTier = profile.rating_tier
        }
        if let runs = try? await api.get(
            "runs?user_id=eq.\(id)&verification=eq.verified&select=id", as: [IdRow].self
        ) {
            stats.verifiedRuns = runs.count
        }
        if let entries = try? await api.get(
            "course_leaderboards?user_id=eq.\(id)&select=rank", as: [Entry].self
        ) {
            stats.wins = entries.filter { $0.rank == 1 }.count
            stats.topTen = entries.filter { $0.rank <= 10 }.count
        }
    }

    private func deleteAccount() async {
        guard let api = environment.api, let userId = await api.userId else {
            notice = "You're not signed in on this device."
            return
        }
        deleting = true
        defer { deleting = false }
        do {
            _ = try await api.rpc("delete_my_account", json: [:])
            // "All its data" has to include what is still on this phone —
            // queued runs and any journalled drive. Otherwise their GPS
            // traces outlive the account they belonged to.
            await environment.purgeLocalData(for: userId)
            // Go through the environment so isSignedIn updates and every
            // view keyed on it refetches — calling api.signOut() directly
            // left the deleted account's stats on screen.
            await environment.signOut()
            notice = "Your account and all its data have been deleted."
        } catch {
            notice = "We couldn't delete your account. Please try again, or contact support."
        }
    }
}

struct ProfileStats {
    var rating = 0
    var ratingTier = "unranked"
    var verifiedRuns = 0
    var wins = 0
    var topTen = 0
}

struct IdRow: Decodable { var id: String }

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
///
/// The server enforces from `profiles.ghost_visibility`, so this MUST write
/// there. It previously only set a local @AppStorage key nothing read or
/// transmitted: choosing "Nobody" changed the UI and kept serving your ghost
/// to strangers.
struct PrivacySettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var ghostVisibility = "everyone"
    @State private var saveError: String?

    var body: some View {
        List {
            Section {
                Picker("Who can race my ghost", selection: $ghostVisibility) {
                    Text("Anyone").tag("everyone")
                    Text("Friends").tag("friends")
                    Text("Nobody").tag("nobody")
                }
                .listRowBackground(SOTheme.surface)
                .onChange(of: ghostVisibility) { _, value in
                    Task { await save(value) }
                }
            } footer: {
                if let saveError {
                    Text(saveError).foregroundStyle(SOTheme.caution)
                } else {
                    Text("Ghosts share only your pace along the course — never your raw location.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SOTheme.ground)
        .navigationTitle("Privacy")
        .task { await load() }
    }

    private func load() async {
        guard let api = environment.api, let id = await api.userId else { return }
        struct Row: Decodable { var ghost_visibility: String }
        if let rows = try? await api.get(
            "profiles?id=eq.\(id)&select=ghost_visibility", as: [Row].self
        ), let row = rows.first {
            ghostVisibility = row.ghost_visibility
        }
    }

    private func save(_ value: String) async {
        guard let api = environment.api, let id = await api.userId else {
            saveError = "Sign in to change this — it is stored on the server."
            return
        }
        do {
            try await api.patch("profiles?id=eq.\(id)", json: ["ghost_visibility": value])
            saveError = nil
        } catch {
            saveError = "Couldn't save that setting. Try again."
            await load()
        }
    }
}
