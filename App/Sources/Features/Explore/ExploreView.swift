import CoreLocation
import SOCore
import SwiftUI

/// Course discovery (spec §§54-55).
///
/// This tab shipped with no query behind it: one bundled demo course and a
/// sentence promising the real catalog "loads here with your account". It
/// never did. Now it asks — `courses_near` when location is granted, and
/// `courses_in_region` when it is not, so the tab has something honest to
/// show in both states.
struct ExploreView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var filter: Filter = .nearby
    @State private var state: LoadState = .loading
    @State private var origin: CLLocationCoordinate2D?

    /// No "New" filter. It existed and was a lie: it reversed the
    /// distance ordering, so it showed the FURTHEST courses and called them
    /// new. The browse RPCs do not return a creation date, so there is
    /// nothing honest to sort by — better one filter fewer than one that
    /// misleads.
    enum Filter: String, CaseIterable, Identifiable {
        case nearby = "Nearby"
        case popular = "Popular"

        var id: String { rawValue }
    }

    enum LoadState {
        case loading
        case ready([CourseRow])
        case needsLocation
        case offline
        case failed(String)
    }

    /// One row of `courses_near` / `courses_in_region`. Snake case because
    /// PostgREST returns the column names as written.
    struct CourseRow: Decodable, Identifiable, Hashable {
        var id: String
        var name: String
        var city: String?
        var region: String?
        var country: String?
        var distance_meters: Double
        var difficulty: Int
        var turn_count: Int
        var driver_count: Int
        /// Present only from the nearby query.
        var meters_away: Double?

        var place: String? {
            [city, region].compactMap { $0 }.first
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases) { item in
                                SelectableChip(
                                    label: item.rawValue,
                                    selected: filter == item
                                ) { filter = item }
                            }
                        }
                    }

                    content
                }
                .padding(18)
            }
            .background(SOTheme.ground)
            .navigationTitle("Explore")
            .refreshable { await load() }
            .task(id: filter) { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(SOTheme.heatStart)
                .frame(maxWidth: .infinity, minHeight: 160)

        case .ready(let rows) where rows.isEmpty:
            EmptyHint(
                icon: "map",
                text: origin == nil
                    ? "No courses here yet. Turn on location and we'll look around you."
                    : "No courses within 50 km of you yet. Pull to refresh, or check back — the catalog grows."
            )

        case .ready(let rows):
            // The count is a fact about what loaded, not a marketing number.
            Text("\(rows.count) \(rows.count == 1 ? "course" : "courses") \(origin == nil ? "in your region" : "near you")")
                .font(.caption.weight(.bold))
                .tracking(1)
                .foregroundStyle(SOTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(rows) { row in
                NavigationLink {
                    CourseDetailView(courseId: row.id)
                } label: {
                    CourseCard(
                        name: row.name,
                        distance: DistanceFormatter.label(meters: row.distance_meters),
                        difficulty: row.difficulty,
                        drivers: row.driver_count,
                        place: row.place,
                        awayText: row.meters_away.map {
                            "\(DistanceFormatter.metric(meters: $0)) away"
                        }
                    )
                }
                .buttonStyle(.plain)
            }

        case .needsLocation:
            LocationPrompt { await load() }

        case .offline:
            #if DEBUG
            NavigationLink {
                CourseDetailView(courseId: "demo")
            } label: {
                CourseCard(
                    name: "Malibu #042",
                    distance: DistanceFormatter.label(meters: 4_300),
                    difficulty: 4,
                    drivers: 0,
                    route: DemoCourse.route
                )
            }
            .buttonStyle(.plain)
            #endif
            EmptyHint(
                icon: "wifi.slash",
                text: "Not connected to a server yet, so this is the built-in demo course."
            )

        case .failed(let message):
            EmptyHint(icon: "exclamationmark.triangle", text: message)
        }
    }

    private func load() async {
        guard let api = environment.api else {
            state = .offline
            return
        }
        origin = LastKnownLocation.coordinate()
        do {
            let rows: [CourseRow]
            if let origin {
                let data = try await api.rpc("courses_near", json: [
                    "origin_lat": origin.latitude,
                    "origin_lon": origin.longitude,
                    "radius_meters": filter == .nearby ? 50_000 : 200_000,
                    "max_results": 50,
                ])
                rows = try JSONDecoder().decode([CourseRow].self, from: data)
            } else if let country = Locale.current.region?.identifier {
                // No location: the device's own region is the only honest
                // guess available, and it is a guess — the UI says "in your
                // region", never "near you".
                let data = try await api.rpc("courses_in_region", json: [
                    "p_country": country,
                    "max_results": 50,
                ])
                rows = try JSONDecoder().decode([CourseRow].self, from: data)
            } else {
                state = .needsLocation
                return
            }
            state = .ready(sorted(rows))
        } catch {
            state = .failed("Couldn't load courses. Pull to refresh.")
        }
    }

    /// `courses_near` already sorts by distance; the other filters re-sort
    /// what came back rather than issuing a different query.
    private func sorted(_ rows: [CourseRow]) -> [CourseRow] {
        switch filter {
        case .nearby: rows
        case .popular: rows.sorted { $0.driver_count > $1.driver_count }
        }
    }
}

/// Shown when location would genuinely improve this screen — never as a
/// gate. The region fallback runs first, so this only appears when even
/// that produced nothing.
private struct LocationPrompt: View {
    @Environment(AppEnvironment.self) private var environment
    let onGranted: () async -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.circle")
                .font(.system(size: 34))
                .foregroundStyle(SOTheme.heatStart)
            Text("Turn on location to see the roads around you.")
                .font(.subheadline)
                .foregroundStyle(SOTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Allow location") {
                environment.sensors.requestPermissions()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await onGranted()
                }
            }
            .buttonStyle(GhostButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .soCard(padding: 22)
    }
}

struct CourseCard: View {
    let name: String
    let distance: String
    let difficulty: Int
    let drivers: Int
    var place: String? = nil
    var awayText: String? = nil
    var route: [GeoCoordinate]?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(SOTheme.elevated)
                if let route {
                    RoutePreview(route: route, lineWidth: 2.5, showsGates: false)
                        .padding(4)
                } else {
                    Image(systemName: "map")
                        .foregroundStyle(SOTheme.textSecondary)
                }
            }
            .frame(width: 86, height: 86)

            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(String(repeating: "★", count: difficulty))
                        .font(.caption)
                        .foregroundStyle(SOTheme.heatEnd)
                    if let place {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(SOTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    SOChip(icon: "road.lanes", text: distance)
                    // Drivers is a real count from the leaderboard, so zero
                    // is shown as zero rather than hidden.
                    SOChip(icon: "person.2", text: "\(drivers)")
                }
                if let awayText {
                    Text(awayText)
                        .font(.caption2)
                        .foregroundStyle(SOTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(SOTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .soCard(padding: 12)
    }
}
