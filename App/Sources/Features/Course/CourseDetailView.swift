import MapKit
import SOCore
import SOCourse
import SwiftUI

/// Course screen (spec §15): route, stats, bests, leaderboard, START.
struct CourseDetailView: View {
    let courseId: String

    @State private var model = CourseDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let course = model.course {
                    Map {
                        MapPolyline(coordinates: course.polyline.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        })
                        .stroke(.green, lineWidth: 4)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .allowsHitTesting(false)

                    HStack(spacing: 18) {
                        Stat(label: "Distance", value: course.distanceText)
                        Stat(label: "Difficulty", value: String(repeating: "★", count: course.difficulty))
                        Stat(label: "Turns", value: "\(course.turnCount)")
                        Stat(label: "Drivers", value: "\(course.drivers)")
                    }

                    if let benchmark = course.benchmarkText {
                        Stat(label: "Course benchmark", value: benchmark)
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
                            .font(.headline.weight(.heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(16)
        }
        .navigationTitle(model.course?.name ?? "Course")
        .task { await model.load(courseId: courseId) }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
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
