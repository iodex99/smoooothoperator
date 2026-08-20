#if DEBUG
import Foundation
import SOGhost
import SOModels
import SOScoring
import SOSimulator
import SOSync
import SOTelemetry
import SwiftUI

/// Scripted self-tour for simulator screenshot capture (launch with
/// SMOOOOTH_DEMO_TOUR=1). Walks every tab, opens the course map, then runs
/// a full mock drive — synthetic sensors through the REAL DriveSession/
/// pipeline (spec §89) — so CI screenshots show the core loop end to end.
/// DEBUG only; the user develops without Apple hardware and CI Macs are
/// the only window.
///
/// EVERY DWELL HERE IS COUPLED TO THE CAPTURE CADENCE IN ios-nightly.yml.
/// `xcrun simctl io screenshot` costs about two seconds, and the workflow
/// sleeps two more, so frames land roughly every four seconds. A stage that
/// dwells for less than about three of those intervals can be photographed
/// once, or missed altogether when the phases align badly — which is not
/// hypothetical: three consecutive runs in August 2026 each produced a
/// different set of frames, and one skipped the live drive entirely.
///
/// So no stage below dwells for less than `stageDwell`. Making the tour
/// slower is free; a screenshot set with a hole in it is not.
struct DemoTourView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection = 0
    @State private var showDriveFlow = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SMOOOOTH_DEMO_TOUR"] == "1"
    }

    /// Minimum time any static screen stays on-screen: three capture
    /// intervals plus margin, so every stage yields at least three frames
    /// and shows up as a run of identical captures downstream.
    static let stageDwell = Duration.seconds(12)

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "flag.checkered") }
                .tag(0)
            ExploreView()
                .tabItem { Label("Explore", systemImage: "map") }
                .tag(1)
            LeaderboardView()
                .tabItem { Label("Leaderboards", systemImage: "trophy") }
                .tag(2)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .fullScreenCover(isPresented: $showDriveFlow) {
            DemoDriveFlow()
                .environment(environment)
        }
        .task {
            for tab in 1...3 {
                try? await Task.sleep(for: Self.stageDwell)
                selection = tab
            }
            try? await Task.sleep(for: Self.stageDwell)
            showDriveFlow = true
        }
    }
}

/// Course map first (tiles get time to load), then a mock drive that
/// actually RACES A GHOST — the ghost is generated from a separate
/// simulated run through the real GhostEngine, so the screenshots exercise
/// the whole competitive path rather than a stubbed one.
private struct DemoDriveFlow: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var stage = Stage.course

    enum Stage { case course, driving, shareCard, garage, flyingStart }

    /// The drive needs room for two distinct things to be photographed: the
    /// moving map, and the result DriveView shows once the run is scored.
    /// At 8x the drive lasts ~25s, so 45s leaves ~20s of settled result —
    /// five or six captures each, with margin.
    private static let drivingDwell = Duration.seconds(45)

    /// A run that crossed the start line at speed.
    ///
    /// Decoded rather than constructed: the public initialiser takes a
    /// PipelineOutcome, and this fixture needs specific numbers rather than
    /// a real evaluation. Codable is the honest way to spell that, and it
    /// keeps the demo from being a reason to widen the Kit's API further.
    static let flyingStartOutcome: DriveRunOutcome = {
        let json = """
        {"provisionalScore":8102,"provisionalVerdict":"questionable",
         "breakdown":{"paceBps":10000,"smoothnessBps":6700,
                      "controlBps":9400,"complianceBps":10000},
         "confidenceScore":88,"durationSeconds":181,"distanceMeters":5120,
         "gatesHit":5,"deviationDetected":false,
         "integrityFlags":["flyingStart"],"rawGPS":[],"rawIMU":[]}
        """
        return try! JSONDecoder().decode(DriveRunOutcome.self, from: Data(json.utf8))
    }()

    var body: some View {
        Group {
            switch stage {
            case .course:
                NavigationStack {
                    CourseDetailView(courseId: "demo")
                }
            case .driving:
                DriveView(
                    polyline: DemoCourse.route,
                    gates: DemoCourse.gates,
                    benchmarkSeconds: 300,
                    // A real rival: a faster ghost built from its own run.
                    ghost: DemoCourse.rivalGhost,
                    courseId: "demo",
                    // 8x, not 30x. THIS IS THE BUG THAT LOST THE LIVE-RUN
                    // SCREENSHOT. At 30x a 3:15 drive is over in about six
                    // seconds — barely one capture interval — and DriveView
                    // then sits on its own result screen for the remaining
                    // forty-odd seconds of this stage. The moving map, which
                    // is the single most compelling thing the app does and
                    // screenshot number one on the listing, existed for one
                    // frame if it existed at all. Run 32341477503 captured
                    // none of it.
                    //
                    // 8x spreads the drive over roughly twenty-five seconds
                    // — six or seven captures — and still leaves time inside
                    // `drivingDwell` for the result to appear and settle.
                    debugEvents: MockSensorFeed.stream(
                        profile: .fastSmooth,
                        route: DemoCourse.route,
                        speedup: 8
                    )
                )
            case .shareCard:
                // The card exactly as ImageRenderer renders it for sharing.
                ZStack {
                    SOTheme.ground.ignoresSafeArea()
                    RunShareCard(
                        score: 8_847,
                        breakdown: ScoreBreakdown(
                            paceBps: 10_000, smoothnessBps: 6_700,
                            controlBps: 10_000, complianceBps: 10_000
                        ),
                        durationText: "3:15",
                        courseName: "Malibu #042",
                        route: DemoCourse.route,
                        verdict: .verified,
                        rankText: "#1 on this course"
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                }
            case .garage:
                NavigationStack {
                    GarageView(demoVehicles: [
                        .init(id: "1", name: "The Golf", make: "Volkswagen",
                              model: "GTI", year: 2019, is_default: true),
                        .init(id: "2", name: "Sunday car", make: "Mazda",
                              model: "MX-5", year: 2015, is_default: false),
                        .init(id: "3", name: "The van", make: "Ford",
                              model: "Transit", year: 2021, is_default: false),
                    ])
                }
            case .flyingStart:
                // The fairness rule made visible: scored, shown, ranked nowhere.
                RunResultView(
                    outcome: Self.flyingStartOutcome,
                    courseId: "demo",
                    route: DemoCourse.route,
                    onDismiss: {}
                )
            }
        }
        .environment(environment)
        .task {
            try? await Task.sleep(for: DemoTourView.stageDwell)
            stage = .driving
            try? await Task.sleep(for: Self.drivingDwell)
            stage = .shareCard
            try? await Task.sleep(for: DemoTourView.stageDwell)
            stage = .garage
            try? await Task.sleep(for: DemoTourView.stageDwell)
            stage = .flyingStart
            // The last stage gets extra: the capture loop must still be
            // running when it appears, and it is the tail of the tour.
            try? await Task.sleep(for: DemoTourView.stageDwell)
        }
    }
}
#endif
