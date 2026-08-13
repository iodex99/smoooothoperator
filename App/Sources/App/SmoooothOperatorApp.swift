import SwiftUI
import SOCore

/// App entry point. Deliberately minimal: all logic lives in SmoooothKit;
/// this layer is adapters + layout only (ADR-0001).
@main
struct SmoooothOperatorApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DemoTourView.isRequested {
                    DemoTourView()
                        .onAppear { environment.hasAcknowledgedSafety = true }
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
            .environment(environment)
            .preferredColorScheme(.dark)
            .task { await environment.loadScoringConfig() }
        }
    }
}
