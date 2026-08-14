import SwiftUI

/// The garage (spec §§13, 74).
///
/// A driver with more than one car wants to know which is faster on a road.
/// The free tier includes one car; a garage is a Pro feature, enforced in
/// the database as well as here — a client-side limit is a suggestion.
struct GarageView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var vehicles: [Vehicle] = []
    @State private var loading = true
    @State private var showAdd = false
    @State private var showPaywall = false
    @State private var notice: String?

    struct Vehicle: Identifiable, Decodable, Hashable {
        var id: String
        var name: String
        var make: String?
        var model: String?
        var year: Int?
        var is_default: Bool

        var subtitle: String {
            [make, model, year.map(String.init)]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { Spacer(); ProgressView().tint(SOTheme.heatStart); Spacer() }
                        .listRowBackground(Color.clear)
                } else if vehicles.isEmpty {
                    Text("Add the car you drive and every run records which one it was.")
                        .font(.subheadline)
                        .foregroundStyle(SOTheme.textSecondary)
                        .listRowBackground(SOTheme.surface)
                } else {
                    ForEach(vehicles) { vehicle in
                        HStack(spacing: 12) {
                            Image(systemName: "car.fill")
                                .foregroundStyle(
                                    vehicle.is_default ? SOTheme.heatStart : SOTheme.textSecondary
                                )
                                .frame(width: 34, height: 34)
                                .background(
                                    (vehicle.is_default ? SOTheme.heatStart : SOTheme.textSecondary)
                                        .opacity(0.12),
                                    in: Circle()
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.name)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                if !vehicle.subtitle.isEmpty {
                                    Text(vehicle.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(SOTheme.textSecondary)
                                }
                            }
                            Spacer()
                            if vehicle.is_default {
                                Text("DEFAULT")
                                    .font(.system(size: 9, weight: .black))
                                    .tracking(1)
                                    .foregroundStyle(SOTheme.heatStart)
                            } else {
                                Button("Make default") { Task { await makeDefault(vehicle) } }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    .tint(SOTheme.textSecondary)
                            }
                        }
                        .listRowBackground(SOTheme.surface)
                    }
                    .onDelete { offsets in
                        Task { await delete(offsets) }
                    }
                }
            } header: {
                Text("Your cars")
            } footer: {
                Text(environment.isPro
                    ? "Pro: add as many cars as you drive."
                    : "The free tier includes one car. Pro adds a garage — and lets you race your cars against each other.")
            }

            Section {
                Button {
                    // The ceiling is the database's to enforce; the UI just
                    // routes an honest "you need Pro" to the paywall.
                    if !environment.isPro && !vehicles.isEmpty {
                        showPaywall = true
                    } else {
                        showAdd = true
                    }
                } label: {
                    Label("Add a car", systemImage: "plus.circle.fill")
                }
                .listRowBackground(SOTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SOTheme.ground)
        .navigationTitle("Garage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showAdd) {
            AddVehicleView { await load() }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        }
    }

    private func load() async {
        defer { loading = false }
        guard let api = environment.api, await api.userId != nil else {
            vehicles = []
            return
        }
        vehicles = (try? await api.get(
            "vehicles?select=id,name,make,model,year,is_default&order=is_default.desc,created_at",
            as: [Vehicle].self
        )) ?? []
    }

    private func makeDefault(_ vehicle: Vehicle) async {
        guard let api = environment.api else { return }
        // Clear first: the database allows exactly one default per driver.
        for other in vehicles where other.is_default {
            try? await api.patch("vehicles?id=eq.\(other.id)", json: ["is_default": false])
        }
        try? await api.patch("vehicles?id=eq.\(vehicle.id)", json: ["is_default": true])
        await load()
    }

    private func delete(_ offsets: IndexSet) async {
        guard let api = environment.api else { return }
        for index in offsets {
            let vehicle = vehicles[index]
            do {
                try await api.delete("vehicles?id=eq.\(vehicle.id)")
            } catch {
                notice = "Couldn't remove that car. Try again."
            }
        }
        await load()
    }
}

/// Adding a car. Only the name is required — most drivers know their car by
/// what they call it, not by its trim level.
struct AddVehicleView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let onSaved: () async -> Void

    @State private var name = ""
    @State private var make = ""
    @State private var model = ""
    @State private var year = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("What you call it — \"The Golf\"", text: $name)
                        .listRowBackground(SOTheme.surface)
                } footer: {
                    Text("This is the name that appears beside your runs.")
                }
                Section("Optional") {
                    TextField("Make", text: $make).listRowBackground(SOTheme.surface)
                    TextField("Model", text: $model).listRowBackground(SOTheme.surface)
                    TextField("Year", text: $year)
                        .keyboardType(.numberPad)
                        .listRowBackground(SOTheme.surface)
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
            .navigationTitle("Add a car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        guard let api = environment.api, let userId = await api.userId else {
            error = "Sign in to keep a garage."
            return
        }
        saving = true
        defer { saving = false }
        var payload: [String: Any] = [
            "user_id": userId,
            "name": name.trimmingCharacters(in: .whitespaces),
        ]
        if !make.isEmpty { payload["make"] = make }
        if !model.isEmpty { payload["model"] = model }
        if let parsed = Int(year), (1900...2100).contains(parsed) { payload["year"] = parsed }
        do {
            _ = try await api.insert("vehicles", json: payload)
            await onSaved()
            dismiss()
        } catch {
            // The database enforces the free-tier ceiling; say so plainly.
            self.error = "Couldn't add that car. The free tier includes one — Pro adds a garage."
        }
    }
}
