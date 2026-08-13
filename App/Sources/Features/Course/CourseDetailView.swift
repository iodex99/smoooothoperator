import MapKit
import SOCore
import SOCourse
import SOGhost
import SwiftUI

/// Course screen (spec §15): the real map with the route trace, stats,
/// benchmark, START. The map is view-only — course geometry is cached,
/// no per-open routing calls (spec §90).
struct CourseDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let courseId: String
    /// Server-fetched course handed over by the caller (Today's Challenge
    /// arrives fully drive-ready) — skips a second fetch.
    var preloaded: CourseDetailModel.Course? = nil

    @State private var model = CourseDetailModel()
    @State private var showPaywall = false
    @State private var raceGhost = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .ready(let course):
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

                    if let rival = model.rival {
                        Toggle(isOn: $raceGhost) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Race \(rival.username)'s ghost")
                                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                                    .foregroundStyle(.white)
                                Text("Their \(rival.score) run, live beside you")
                                    .font(.caption)
                                    .foregroundStyle(SOTheme.textSecondary)
                            }
                        }
                        .tint(SOTheme.heatStart)
                        .soCard(padding: 14)
                    }

                    if environment.canStartRun {
                        NavigationLink {
                            DriveView(
                                polyline: course.polyline,
                                gates: course.gates,
                                benchmarkSeconds: course.benchmarkSeconds ?? 0,
                                ghost: raceGhost ? model.rival?.ghost : nil,
                                courseId: courseId
                            )
                            .navigationBarBackButtonHidden()
                            .onAppear { environment.recordRunStarted() }
                        } label: {
                            Text("START CHALLENGE")
                        }
                        .buttonStyle(HeatButtonStyle())
                        .padding(.top, 6)

                        if let remaining = environment.runsRemainingToday {
                            Text(remaining == 1
                                ? "1 run left today on the free tier"
                                : "\(remaining) runs left today on the free tier")
                                .font(.caption)
                                .foregroundStyle(SOTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        // The free limit is the one moment of genuine upgrade
                        // intent in the product — meet it here, not buried in
                        // a settings tab.
                        VStack(spacing: 8) {
                            Text("You've used today's free runs")
                                .font(.system(.headline, design: .rounded).weight(.heavy))
                                .foregroundStyle(.white)
                            Text("Pro drives as many challenges as you like — today and every day.")
                                .font(.caption)
                                .foregroundStyle(SOTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("GO PRO") { showPaywall = true }
                                .buttonStyle(HeatButtonStyle())
                        }
                        .soCard(padding: 18)
                        .padding(.top, 6)
                    }
                case .loading:
                    ProgressView()
                        .tint(SOTheme.heatStart)
                        .frame(maxWidth: .infinity, minHeight: 300)
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(SOTheme.caution)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(SOTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") {
                            Task {
                                model.state = .loading
                                await model.load(
                                    courseId: courseId,
                                    preloaded: preloaded,
                                    api: environment.api
                                )
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(18)
        }
        .background(SOTheme.ground)
        .navigationTitle(model.course?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(courseId: courseId, preloaded: preloaded, api: environment.api)
            await model.loadRival(courseId: courseId, api: environment.api)
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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

    enum State {
        case loading
        case ready(Course)
        case failed(String)
    }

    var state: State = .loading
    /// The best ghost available to race here, if any.
    var rival: (ghost: GhostTrajectory, username: String, score: Int)?

    /// Convenience for the view's title.
    var course: Course? {
        if case .ready(let course) = state { return course }
        return nil
    }

    /// Ghosts are a bonus, never a blocker: a failure here leaves the
    /// course fully driveable.
    func loadRival(courseId: String, api: SupabaseAPI?) async {
        guard let api, await api.userId != nil else { return }
        rival = try? await api.bestGhost(courseId: courseId)
    }

    func load(courseId: String, preloaded: Course? = nil, api: SupabaseAPI?) async {
        if let preloaded {
            state = .ready(preloaded)
            return
        }
        #if DEBUG
        if courseId == "demo" {
            let route = DemoCourse.route
            state = .ready(Course(
                name: "Malibu #042",
                polyline: route,
                gates: DemoCourse.gates,
                distanceText: Measurement(value: 4.3, unit: UnitLength.kilometers)
                    .formatted(.measurement(width: .abbreviated)),
                difficulty: 4,
                turnCount: 23,
                drivers: 0,
                benchmarkSeconds: 300
            ))
            return
        }
        #endif
        guard let api, await api.userId != nil else {
            // Never spin forever: say what is wrong and offer a way out.
            state = .failed("Sign in to load this course.")
            return
        }
        do {
            struct Row: Decodable {
                var name: String
                var distance_meters: Double
                var difficulty: Int
                var turn_count: Int
                var benchmark_seconds: Int?
            }
            let rows = try await api.get(
                "courses?id=eq.\(courseId)&select=name,distance_meters,difficulty,turn_count,benchmark_seconds",
                as: [Row].self
            )
            guard let row = rows.first else {
                state = .failed("This course is no longer available.")
                return
            }
            let route = try await api.courseRoute(courseId: courseId)
            state = .ready(Course(
                name: row.name,
                polyline: route.polyline,
                gates: route.gates,
                distanceText: Measurement(value: row.distance_meters, unit: UnitLength.meters)
                    .converted(to: .kilometers)
                    .formatted(.measurement(width: .abbreviated)),
                difficulty: row.difficulty,
                turnCount: row.turn_count,
                drivers: 0,
                benchmarkSeconds: row.benchmark_seconds.map(Double.init)
            ))
        } catch {
            state = .failed("Couldn't load this course. Check your connection and try again.")
        }
    }
}

#if DEBUG
import SOSimulator
import SOTelemetry

/// The simulator's demo course — mock mode drives it end to end (spec §89).
enum DemoCourse {
    static let route = TelemetrySimulator.demoRoute(seed: 7)
    static let gates = [0, route.count / 3, 2 * route.count / 3, route.count - 1]
        .enumerated().map { sequence, index in
            Checkpoint(sequence: sequence, center: route[index], radiusMeters: 40)
        }

    /// A rival built from a genuinely separate simulated run, through the
    /// real GhostEngine — so mock mode exercises the whole ghost path
    /// (generation, storage shape, interpolation, gap math, map position)
    /// instead of a hand-written stand-in.
    static let rivalGhost: GhostTrajectory? = {
        let run = TelemetrySimulator(profile: .fastSmooth, seed: 99).simulate(route: route)
        let processed = TrajectoryProcessor().process(run.gps)
        return try? GhostEngine.generate(
            trajectory: processed,
            polyline: route,
            checkpoints: gates
        )
    }()
}
#endif
