import SwiftUI

/// Friends (spec §§28-31): requests, list, challenge — no chat, no feed.
///
/// Every control here used to be an empty function body: you typed a
/// username, tapped Send, saw nothing happen, and reasonably assumed the
/// request went out. It didn't. Now each action really hits the database
/// and reports what happened.
struct FriendsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var username = ""
    @State private var friends: [Friend] = []
    @State private var incoming: [Request] = []
    @State private var outgoing: [Request] = []
    @State private var notice: String?
    @State private var working = false

    struct Friend: Identifiable, Hashable {
        var id: String
        var username: String
    }

    struct Request: Identifiable, Hashable {
        var id: String
        var otherId: String
        var username: String
    }

    var body: some View {
        List {
            Section("Add a friend") {
                HStack {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit { Task { await sendRequest() } }
                    Button("Send") { Task { await sendRequest() } }
                        .disabled(username.count < 3 || working)
                        .buttonStyle(.borderless)
                }
                .listRowBackground(SOTheme.surface)
                ShareLink(item: "Race me on \(Brand.name) — \(Brand.domain)") {
                    Label("Invite friends", systemImage: "square.and.arrow.up")
                }
                .listRowBackground(SOTheme.surface)
            }

            if !incoming.isEmpty {
                Section("Requests") {
                    ForEach(incoming) { request in
                        HStack {
                            Text(request.username)
                            Spacer()
                            Button("Accept") { Task { await respond(request, accept: true) } }
                                .buttonStyle(.borderedProminent)
                                .tint(SOTheme.heatStart)
                            Button("Decline") { Task { await respond(request, accept: false) } }
                                .buttonStyle(.bordered)
                        }
                        .listRowBackground(SOTheme.surface)
                    }
                }
            }

            if !outgoing.isEmpty {
                Section("Sent") {
                    ForEach(outgoing) { request in
                        HStack {
                            Text(request.username)
                            Spacer()
                            Text("Pending")
                                .font(.caption)
                                .foregroundStyle(SOTheme.textSecondary)
                        }
                        .listRowBackground(SOTheme.surface)
                    }
                }
            }

            Section("Friends") {
                if !environment.isSignedIn {
                    // Signed out this list is empty for a reason that has
                    // nothing to do with how many friends you have. Saying
                    // "no friends yet" would be both wrong and unkind.
                    SignInPrompt(
                        icon: "person.2.fill",
                        title: "Rivals make you smoother",
                        message: "Sign in to add friends, send challenges and race their ghosts."
                    ) { await load() }
                } else if friends.isEmpty {
                    ContentUnavailableView(
                        "No friends yet",
                        systemImage: "person.2",
                        description: Text("Friend competition is the whole point — invite someone.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(friends) { friend in
                        HStack {
                            Text(friend.username)
                            Spacer()
                            Button("Remove") { Task { await remove(friend) } }
                                .buttonStyle(.borderless)
                                .tint(SOTheme.textSecondary)
                                .font(.caption)
                        }
                        .listRowBackground(SOTheme.surface)
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .scrollContentBackground(.hidden)
        .background(SOTheme.ground)
        .refreshable { await load() }
        .task { await load() }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        }
    }

    // MARK: - Data

    private struct FriendshipRow: Decodable {
        var id: String
        var requester_id: String
        var addressee_id: String
        var status: String
    }

    private struct ProfileRow: Decodable {
        var id: String
        var username: String
    }

    private func load() async {
        guard let api = environment.api, let me = await api.userId else {
            friends = []; incoming = []; outgoing = []
            return
        }
        guard let rows = try? await api.get(
            "friendships?select=id,requester_id,addressee_id,status", as: [FriendshipRow].self
        ) else { return }

        // One lookup for every counterpart, rather than a query per row.
        let otherIds = Set(rows.map { $0.requester_id == me ? $0.addressee_id : $0.requester_id })
        var names: [String: String] = [:]
        if !otherIds.isEmpty,
           let profiles = try? await api.get(
               "profiles?id=in.(\(otherIds.joined(separator: ",")))&select=id,username",
               as: [ProfileRow].self
           ) {
            names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.username) })
        }

        friends = rows.filter { $0.status == "accepted" }.map { row in
            let other = row.requester_id == me ? row.addressee_id : row.requester_id
            return Friend(id: other, username: names[other] ?? "driver")
        }
        incoming = rows
            .filter { $0.status == "pending" && $0.addressee_id == me }
            .map { Request(id: $0.id, otherId: $0.requester_id,
                           username: names[$0.requester_id] ?? "driver") }
        outgoing = rows
            .filter { $0.status == "pending" && $0.requester_id == me }
            .map { Request(id: $0.id, otherId: $0.addressee_id,
                           username: names[$0.addressee_id] ?? "driver") }
    }

    private func sendRequest() async {
        guard let api = environment.api, let me = await api.userId else {
            notice = "Sign in to add friends."
            return
        }
        let handle = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard handle != "" else { return }
        working = true
        defer { working = false }

        guard let matches = try? await api.get(
            "profiles?username=eq.\(handle)&select=id,username", as: [ProfileRow].self
        ), let match = matches.first else {
            notice = "No driver called \(handle)."
            return
        }
        guard match.id != me else {
            notice = "That's you."
            return
        }
        do {
            _ = try await api.insert("friendships", json: [
                "requester_id": me,
                "addressee_id": match.id,
            ])
            username = ""
            notice = "Request sent to \(match.username)."
            await load()
        } catch {
            // The unique constraint means "already connected" is the common case.
            notice = "You've already got a request with \(match.username)."
        }
    }

    private func respond(_ request: Request, accept: Bool) async {
        guard let api = environment.api else { return }
        do {
            try await api.patch(
                "friendships?id=eq.\(request.id)",
                json: ["status": accept ? "accepted" : "declined"]
            )
            await load()
        } catch {
            notice = "Couldn't update that request. Try again."
        }
    }

    private func remove(_ friend: Friend) async {
        guard let api = environment.api, let me = await api.userId else { return }
        do {
            try await api.delete(
                "friendships?or=(and(requester_id.eq.\(me),addressee_id.eq.\(friend.id)),"
                    + "and(requester_id.eq.\(friend.id),addressee_id.eq.\(me)))"
            )
            await load()
        } catch {
            notice = "Couldn't remove that friend. Try again."
        }
    }
}
