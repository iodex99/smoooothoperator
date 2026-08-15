import MapKit
import SOCore
import SOCourse
import SOGhost
import SwiftUI

/// Course screen (spec §15): the real map with the route trace, stats,
/// benchmark, START. The map is view-only — course geometry is cached,
/// no per-open routing calls (spec §90).
struct CourseDetailView: View {
    @State private var showSignIn = false
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
                            .font(.system(.title, design: .rounded).weight(.black))
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

                    // The garage's whole selling point, finally on screen:
                    // which of YOUR cars is fastest on THIS road. It was
                    // answerable only in SQL until now.
                    if model.vehicleBests.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("YOUR CARS HERE")
                                .font(.caption2.weight(.black))
                                .tracking(1.4)
                                .foregroundStyle(SOTheme.textSecondary)
                            ForEach(model.vehicleBests) { best in
                                HStack(spacing: 10) {
                                    Image(systemName: "car.fill")
                                        .font(.caption)
                                        .foregroundStyle(
                                            best.best_score == nil
                                                ? SOTheme.textSecondary
                                                : SOTheme.heatStart
                                        )
                                    Text(best.vehicle_name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    // No time is shown as no time, never as
                                    // a zero — a car you have not driven
                                    // here has not lost to anything.
                                    Text(best.best_score.map { "\($0)" } ?? "—")
                                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                                        .monospacedDigit()
                                        .foregroundStyle(
                                            best.best_score == nil
                                                ? SOTheme.textSecondary
                                                : .white
                                        )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                case .needsSignIn:
                    VStack(spacing: 16) {
                        ZStack {
                            GlowRing(progress: 1, lineWidth: 5)
                                .frame(width: 78, height: 78)
                            Image(systemName: "flag.checkered")
                                .font(.title2)
                                .foregroundStyle(SOTheme.heat)
                        }
                        Text("Sign in to open this course")
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("Courses, ghosts and leaderboards need an account. It takes one tap.")
                            .font(.subheadline)
                            .foregroundStyle(SOTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sign in") { showSignIn = true }
                            .buttonStyle(HeatButtonStyle())
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, minHeight: 320)

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
        .sheet(isPresented: $showSignIn, onDismiss: {
            // Signing in is what was missing — retry immediately rather than
            // leaving the driver on the prompt they just satisfied.
            Task {
                model.state = .loading
                await model.load(
                    courseId: courseId, preloaded: preloaded, api: environment.api
                )
            }
        }) {
            SignInView()
        }
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
        /// Not an error. Course geometry is authenticated-only by design, so
        /// a signed-out driver who arrives here — from Explore, which lists
        /// courses to anyone, or from a shared challenge link, whose whole
        /// point is to open for someone who has not installed the app — needs
        /// a way forward, not a dead end reading "Sign in to load this
        /// course."
        case needsSignIn
    }

    var state: State = .loading
    /// The best ghost available to race here, if any.
    var rival: (ghost: GhostTrajectory, username: String, score: Int)?

    /// Per-car bests on this course. Only shown when there is more than one
    /// car — a single-car driver has nothing to compare and does not need a
    /// card telling them so.
    struct VehicleBest: Decodable, Identifiable, Hashable {
        var vehicle_id: String
        var vehicle_name: String
        var best_score: Int?
        var id: String { vehicle_id }
    }
    var vehicleBests: [VehicleBest] = []

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
                distanceText: DistanceFormatter.label(meters: 4_300),
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
            state = .needsSignIn
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
            // CONCURRENTLY. These three requests do not depend on each
            // other, and they were awaited one after another — three round
            // trips in series. On a mobile connection at ~100 ms that is a
            // third of a second of spinner for no reason, while the driver
            // stands at the side of a road.
            async let rowsTask = api.get(
                "courses?id=eq.\(courseId)&select=name,distance_meters,difficulty,turn_count,benchmark_seconds",
                as: [Row].self
            )
            async let routeTask = api.courseRoute(courseId: courseId)
            // Best-effort: a driver with no garage, or a failure here, must
            // never stop the course from loading.
            async let bestsTask = try? api.rpc("my_vehicle_bests", json: ["p_course": courseId])

            let rows = try await rowsTask
            guard let row = rows.first else {
                state = .failed("This course is no longer available.")
                return
            }
            vehicleBests = (await bestsTask)
                .flatMap { try? JSONDecoder().decode([VehicleBest].self, from: $0) } ?? []
            let route = try await routeTask
            state = .ready(Course(
                name: row.name,
                polyline: route.polyline,
                gates: route.gates,
                distanceText: DistanceFormatter.label(meters: row.distance_meters),
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
