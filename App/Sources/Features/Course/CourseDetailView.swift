import MapKit
import SOCore
import SOCourse
import SwiftUI

/// Course screen (spec §15): the real map with the route trace, stats,
/// benchmark, START. The map is view-only — course geometry is cached,
/// no per-open routing calls (spec §90).
struct CourseDetailView: View {
    let courseId: String

    @State private var model = CourseDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let course = model.course {
                    CourseMapView(course: course)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(SOTheme.hairline, lineWidth: 1)
                        )

                    HStack {
                        Text(course.name)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(repeating: "★", count: course.difficulty))
                            .font(.headline)
                            .foregroundStyle(SOTheme.heatEnd)
                    }

                    HStack(spacing: 10) {
                        StatTile(label: "Distance", value: course.distanceText)
                        StatTile(label: "Turns", value: "\(course.turnCount)")
                        StatTile(label: "Drivers", value: "\(course.drivers)")
                    }

                    if let benchmark = course.benchmarkText {
                        HStack(spacing: 14) {
                            Image(systemName: "timer")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(SOTheme.heatStart)
                                .frame(width: 44, height: 44)
                                .background(SOTheme.heatStart.opacity(0.13), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("COURSE BENCHMARK")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1)
                                    .foregroundStyle(SOTheme.textSecondary)
                                Text(benchmark)
                                    .font(.system(.title3, design: .rounded).weight(.heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("PACE TARGET")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1)
                                    .foregroundStyle(SOTheme.textSecondary)
                                Text("Match it, smoothly")
                                    .font(.footnote)
                                    .foregroundStyle(SOTheme.textSecondary)
                            }
                        }
                        .soCard(padding: 14)
                    }

                    NavigationLink {
                        DriveView(
                            polyline: course.polyline,
                            gates: course.gates,
                            benchmarkSeconds: course.benchmarkSeconds ?? 0,
                            ghost: nil,
                            courseId: courseId
                        )
                        .navigationBarBackButtonHidden()
                    } label: {
                        Text("START CHALLENGE")
                    }
                    .buttonStyle(HeatButtonStyle())
                    .padding(.top, 6)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(18)
        }
        .background(SOTheme.ground)
        .navigationTitle(model.course?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(courseId: courseId) }
    }
}

/// The real map: dark tiles, heat route, start/finish gate markers.
struct CourseMapView: View {
    let course: CourseDetailModel.Course

    var body: some View {
        Map(interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coordinates)
                .stroke(
                    SOTheme.heatStart,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
            if let start = coordinates.first {
                Annotation("START", coordinate: start) {
                    GateMarker(color: SOTheme.verified, icon: "flag.fill")
                }
            }
            if let finish = coordinates.last {
                Annotation("FINISH", coordinate: finish) {
                    GateMarker(color: .white, icon: "flag.checkered")
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    private var coordinates: [CLLocationCoordinate2D] {
        course.polyline.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}

struct GateMarker: View {
    let color: Color
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(color, in: Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }
}

@MainActor
@Observable
final class CourseDetailModel {
    struct Course {
        var name: String
        var polyline: [GeoCoordinate]
        var gates: [Checkpoint]
        var distanceText: String
        var difficulty: Int
        var turnCount: Int
        var drivers: Int
        var benchmarkSeconds: Double?

        var benchmarkText: String? {
            benchmarkSeconds.map {
                Duration.seconds($0).formatted(.time(pattern: .minuteSecond))
            }
        }
    }

    var course: Course?

    func load(courseId: String) async {
        // Server fetch lands with device wiring; the demo course keeps the
        // full drive loop usable in mock mode today.
        #if DEBUG
        if courseId == "demo" {
            let route = DemoCourse.route
            course = Course(
                name: "Malibu #042",
                polyline: route,
                gates: DemoCourse.gates,
                distanceText: Measurement(value: 4.3, unit: UnitLength.kilometers)
                    .formatted(.measurement(width: .abbreviated)),
                difficulty: 4,
                turnCount: 23,
                drivers: 0,
                benchmarkSeconds: 300
            )
            return
        }
        #endif
    }
}

#if DEBUG
import SOSimulator

/// The simulator's demo course — mock mode drives it end to end (spec §89).
enum DemoCourse {
    static let route = TelemetrySimulator.demoRoute(seed: 7)
    static let gates = [0, route.count / 3, 2 * route.count / 3, route.count - 1]
        .enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 40)
        }
}
#endif
