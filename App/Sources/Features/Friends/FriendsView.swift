import SwiftUI

/// Friends (spec §§28-31): requests, list, challenge — no chat, no feed.
struct FriendsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var username = ""
    @State private var friends: [Friend] = []
    @State private var pending: [Friend] = []

    struct Friend: Identifiable, Decodable {
        var id: String
        var username: String
    }

    var body: some View {
        List {
            Section("Add a friend") {
                HStack {
                    TextField("username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Send") { Task { await sendRequest() } }
                        .disabled(username.count < 3)
                }
                ShareLink(item: "Race me on Smooooth Operator — smooooth.app") {
                    Label("Invite friends", systemImage: "square.and.arrow.up")
                }
            }

            if !pending.isEmpty {
                Section("Requests") {
                    ForEach(pending) { friend in
                        HStack {
                            Text(friend.username)
                            Spacer()
                            Button("Accept") { Task { await respond(friend, accept: true) } }
                                .buttonStyle(.borderedProminent)
                            Button("Decline") { Task { await respond(friend, accept: false) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section("Friends") {
                if friends.isEmpty {
                    ContentUnavailableView(
                        "No friends yet",
                        systemImage: "person.2",
                        description: Text("Friend competition is the whole point — invite someone.")
                    )
                } else {
                    ForEach(friends) { friend in
                        Text(friend.username)
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .task { await load() }
    }

    private func load() async {
        // friendship list queries land with device wiring.
    }

    private func sendRequest() async {
        // resolve username → profiles.id, insert friendships row.
    }

    private func respond(_ friend: Friend, accept: Bool) async {
        // update friendships.status per the DB state machine.
    }
}
