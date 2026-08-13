import SwiftUI

/// Your driver identity (spec §13).
///
/// Without this every competitor on every leaderboard is called
/// `driver_8f3a1c9e2b7d`, friends can't find each other by a name neither
/// of them can set, and the Country board — which needs a country nobody
/// could enter — is unreachable.
struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var displayName = ""
    @State private var country = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    /// Matches the database constraint exactly, so the user learns the rule
    /// here rather than from a rejected save.
    private var usernameIsValid: Bool {
        username.range(of: "^[a-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    var body: some View {
        List {
            Section {
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowBackground(SOTheme.surface)
                TextField("Display name (optional)", text: $displayName)
                    .listRowBackground(SOTheme.surface)
            } header: {
                Text("Identity")
            } footer: {
                Text(username.isEmpty || usernameIsValid
                    ? "3–20 characters: lowercase letters, numbers and underscores. This is the name on every leaderboard."
                    : "Lowercase letters, numbers and underscores only, 3–20 characters.")
                    .foregroundStyle(usernameIsValid || username.isEmpty
                        ? SOTheme.textSecondary
                        : SOTheme.caution)
            }

            Section {
                Picker("Country", selection: $country) {
                    Text("Not set").tag("")
                    ForEach(Self.countries, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .listRowBackground(SOTheme.surface)
            } footer: {
                Text("Sets your national leaderboard. Never derived from your location.")
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(SOTheme.caution)
                        .listRowBackground(SOTheme.surface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SOTheme.ground)
        .navigationTitle("Your profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!usernameIsValid || saving)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard !loaded, let api = environment.api, let id = await api.userId else { return }
        struct Row: Decodable {
            var username: String
            var display_name: String
            var country: String?
        }
        if let rows = try? await api.get(
            "profiles?id=eq.\(id)&select=username,display_name,country", as: [Row].self
        ), let row = rows.first {
            username = row.username
            displayName = row.display_name
            country = row.country ?? ""
        }
        loaded = true
    }

    private func save() async {
        guard let api = environment.api, let id = await api.userId else {
            error = "Sign in to set your profile."
            return
        }
        saving = true
        defer { saving = false }
        var payload: [String: Any] = [
            "username": username,
            "display_name": displayName,
        ]
        // Empty means "not set", not an empty string the check constraint
        // would reject.
        payload["country"] = country.isEmpty ? NSNull() : country
        do {
            try await api.patch("profiles?id=eq.\(id)", json: payload)
            dismiss()
        } catch {
            // The unique index on username is the overwhelmingly likely cause.
            self.error = "That username is taken. Try another."
        }
    }

    /// The markets the catalog actually covers (docs/COURSES.md), plus a
    /// deliberate long tail — a driver in an unlisted country still gets
    /// global and friends boards.
    static let countries: [(String, String)] = [
        ("US", "United States"), ("GB", "United Kingdom"), ("AU", "Australia"),
        ("CA", "Canada"), ("NZ", "New Zealand"), ("IE", "Ireland"),
        ("DE", "Germany"), ("CH", "Switzerland"), ("AT", "Austria"),
        ("FR", "France"), ("IT", "Italy"), ("ES", "Spain"), ("PT", "Portugal"),
        ("NL", "Netherlands"), ("BE", "Belgium"), ("NO", "Norway"),
        ("SE", "Sweden"), ("DK", "Denmark"), ("FI", "Finland"),
        ("IS", "Iceland"), ("PL", "Poland"), ("CZ", "Czechia"),
        ("SI", "Slovenia"), ("HR", "Croatia"), ("GR", "Greece"),
        ("IN", "India"), ("AE", "United Arab Emirates"), ("ZA", "South Africa"),
        ("JP", "Japan"), ("SG", "Singapore"), ("MY", "Malaysia"),
        ("BR", "Brazil"), ("MX", "Mexico"), ("AR", "Argentina"),
    ]
}
