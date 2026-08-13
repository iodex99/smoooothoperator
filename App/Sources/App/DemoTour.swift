#if DEBUG
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
struct DemoTourView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection = 0
    @State private var showDriveFlow = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["SMOOOOTH_DEMO_TOUR"] == "1"
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
            DemoDriveFlow()
                .environment(environment)
        }
        .task {
            for tab in 1...3 {
                try? await Task.sleep(for: .seconds(6))
                selection = tab
            }
            try? await Task.sleep(for: .seconds(6))
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

    enum Stage { case course, driving, shareCard }

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
                    debugEvents: MockSensorFeed.stream(
                        profile: .fastSmooth,
                        route: DemoCourse.route,
                        speedup: 30
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
            }
        }
        .environment(environment)
        .task {
            try? await Task.sleep(for: .seconds(10))
            stage = .driving
            // Long enough for the 30x mock drive to finish and be scored.
            try? await Task.sleep(for: .seconds(50))
            stage = .shareCard
        }
    }
}
#endif
