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
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    NavigationLink {
                        CourseDetailView(courseId: "demo")
                    } label: {
                        CourseCard(
                            name: "Malibu #042",
                            distance: "4.3 km",
                            difficulty: 4,
                            drivers: 0
                        )
                    }
                    .buttonStyle(.plain)

                    EmptyHint(
                        icon: "square.grid.2x2",
                        text: "Public and friend courses appear here as the catalog grows."
                    )
                }
                .padding(16)
            }
            .navigationTitle("Explore")
        }
    }
}

struct CourseCard: View {
    let name: String
    let distance: String
    let difficulty: Int
    let drivers: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.headline)
            HStack(spacing: 14) {
                Label(distance, systemImage: "road.lanes")
                Text(String(repeating: "★", count: difficulty))
                Label("\(drivers)", systemImage: "person.2")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
    }
}
