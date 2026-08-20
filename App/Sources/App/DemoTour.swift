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

    /// One screen per app launch, from SMOOOOTH_DEMO_TOUR_STAGE.
    ///
    /// The timed walk below still exists and still works for watching the
    /// flow by hand, but CI no longer infers anything from it. Inferring was
    /// tried three ways — by filename, by position among distinct frames,
    /// and by position among stable ones — and each broke differently: an
    /// extra stable segment in run 32349143107 shifted every tour pick by
    /// one, so the slot labelled "run complete" held the course detail
    /// screen and nothing detected it. The mapping was plausible, ordered,
    /// internally consistent, and wrong.
    ///
    /// Naming the stage removes the inference entirely.
    static var stage: String? {
        ProcessInfo.processInfo.environment["SMOOOOTH_DEMO_TOUR_STAGE"]
    }

    /// Minimum time any static screen stays on-screen: three capture
    /// intervals plus margin, so every stage yields at least three frames
    /// and shows up as a run of identical captures downstream.
    static let stageDwell = Duration.seconds(12)

    /// Tab index for a named tab stage, if this launch asked for one.
    private var requestedTab: Int? {
        switch Self.stage {
        case "home": 0
        case "explore": 1
        case "leaderboards": 2
        case "profile": 3
        default: nil
        }
    }

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
            DemoDriveFlow(fixedStage: DemoDriveFlow.Stage(named: Self.stage))
                .environment(environment)
        }
        .task {
            // A named stage means one screen, this launch, no walking.
            if let requestedTab {
                selection = requestedTab
                return
            }
            if DemoDriveFlow.Stage(named: Self.stage) != nil {
                showDriveFlow = true
                return
            }
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
    /// When set, this launch shows exactly this stage and never advances.
    var fixedStage: Stage? = nil

    @State private var stage = Stage.course

    enum Stage {
        case course, driving, driveResult, shareCard, garage, flyingStart

        init?(named name: String?) {
            switch name {
            case "course": self = .course
            case "driving": self = .driving
            case "driveResult": self = .driveResult
            case "shareCard": self = .shareCard
            case "garage": self = .garage
            case "flyingStart": self = .flyingStart
            default: return nil
            }
        }
    }

    /// The drive needs room for two distinct things to be photographed: the
    /// moving map, and the result DriveView shows once the run is scored.
    /// At 4x the drive lasts ~49s, so 80s leaves ~30s of settled result.
    /// Sized for the case where the drive runs FASTER than the arithmetic
    /// predicts, which is what actually happens.
    private static let drivingDwell = Duration.seconds(80)

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

    /// The result of a clean run, for the screenshot that shows what a good
    /// drive looks like.
    ///
    /// A FIXTURE, like `flyingStartOutcome`, and for the same reason: this
    /// screen appears partway through the live drive, so photographing the
    /// real one means waiting an amount of time nobody can predict — the
    /// simulator dilates the app's clock unpredictably under capture load.
    /// Rendering it directly is the difference between a screenshot that is
    /// always there and one that is there most of the time.
    ///
    /// The numbers match the share card in `.shareCard` so the two screens
    /// tell one consistent story.
    static let verifiedOutcome: DriveRunOutcome = {
        let json = """
        {"provisionalScore":8847,"provisionalVerdict":"verified",
         "breakdown":{"paceBps":10000,"smoothnessBps":6700,
                      "controlBps":10000,"complianceBps":10000},
         "confidenceScore":96,"durationSeconds":195,"distanceMeters":4300,
         "gatesHit":6,"deviationDetected":false,
         "integrityFlags":[],"rawGPS":[],"rawIMU":[]}
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
                    // 4x, down from 30x and then 8x. THIS IS THE BUG THAT
                    // LOST THE LIVE-RUN SCREENSHOT. At 30x a 3:15 drive was
                    // over in about six seconds — barely one capture — and
                    // DriveView then sat on its own result for the rest of
                    // the stage. The moving map, the most compelling thing
                    // the app does and screenshot one on the listing, existed
                    // for one frame if it existed at all.
                    //
                    // 8x was measured, not guessed, and was still not enough:
                    // run 32343419245 caught the drive, run 32344524536 got a
                    // single frame of it. The arithmetic says 8x is ~24s and
                    // six captures; reality delivered one, so the pacing is
                    // evidently variable on a loaded runner in a way the
                    // arithmetic does not model.
                    //
                    // 4x buys margin instead of precision: ~49s of drive, so
                    // even running three times faster than expected still
                    // leaves four or five frames of moving map.
                    debugEvents: MockSensorFeed.stream(
                        profile: .fastSmooth,
                        route: DemoCourse.route,
                        speedup: 4
                    )
                )
            case .driveResult:
                RunResultView(
                    outcome: Self.verifiedOutcome,
                    courseId: "demo",
                    route: DemoCourse.route,
                    onDismiss: {}
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
            if let fixedStage {
                stage = fixedStage
                return
            }
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
