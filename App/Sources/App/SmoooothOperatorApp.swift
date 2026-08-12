import SwiftUI
import SOCore

/// App entry point. Deliberately minimal: all logic lives in SmoooothKit;
/// this layer is adapters + layout only (ADR-0001).
@main
struct SmoooothOperatorApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .preferredColorScheme(.dark)
                .task { await environment.loadScoringConfig() }
        }
    }
}
