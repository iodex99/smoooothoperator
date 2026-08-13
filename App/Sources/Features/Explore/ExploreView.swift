import SOCore
import SwiftUI

/// Course discovery (spec §§54-55): nearby / popular / new / friends,
/// deliberately few filters in V1.
struct ExploreView: View {
    @State private var filter: Filter = .nearby

    enum Filter: String, CaseIterable, Identifiable {
        case nearby = "Nearby"
        case popular = "Popular"
        case new = "New"
        case friends = "Friends"

        var id: String { rawValue }
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

                    NavigationLink {
                        CourseDetailView(courseId: "demo")
                    } label: {
                        CourseCard(
                            name: "Malibu #042",
                            distance: "4.3 km",
                            difficulty: 4,
                            drivers: 0,
                            route: demoRoute
                        )
                    }
                    .buttonStyle(.plain)

                    EmptyHint(
                        icon: "globe.americas",
                        text: "397 platform courses across 30 countries load here with your account — plus every course your friends create."
                    )
                }
                .padding(18)
            }
            .background(SOTheme.ground)
            .navigationTitle("Explore")
        }
    }

    private var demoRoute: [GeoCoordinate]? {
        #if DEBUG
        DemoCourse.route
        #else
        nil
        #endif
    }
}

struct CourseCard: View {
    let name: String
    let distance: String
    let difficulty: Int
    let drivers: Int
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
                Text(String(repeating: "★", count: difficulty))
                    .font(.caption)
                    .foregroundStyle(SOTheme.heatEnd)
                HStack(spacing: 6) {
                    SOChip(icon: "road.lanes", text: distance)
                    SOChip(icon: "person.2", text: "\(drivers)")
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
