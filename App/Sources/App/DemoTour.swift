#if DEBUG
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

/// Course map first (tiles get time to load), then the mock drive.
private struct DemoDriveFlow: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var driving = false

    var body: some View {
        Group {
            if driving {
                DriveView(
                    polyline: DemoCourse.route,
                    gates: DemoCourse.gates,
                    benchmarkSeconds: 300,
                    ghost: nil,
                    courseId: "demo",
                    debugEvents: MockSensorFeed.stream(
                        profile: .fastSmooth,
                        route: DemoCourse.route,
                        speedup: 30
                    )
                )
            } else {
                NavigationStack {
                    CourseDetailView(courseId: "demo")
                }
            }
        }
        .environment(environment)
        .task {
            try? await Task.sleep(for: .seconds(10))
            driving = true
        }
    }
}
#endif
