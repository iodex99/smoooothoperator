import SwiftUI
import SOCore

/// App entry point. Deliberately minimal: all logic lives in SmoooothKit;
/// this layer is adapters + layout only (ADR-0001).
@main
struct SmoooothOperatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DemoTourView.isRequested {
                    DemoTourView()
                        .onAppear { environment.completeOnboarding() }
                } else if OnboardingDemo.isRequested {
                    OnboardingView(demoAutoAdvance: true)
                } else if !environment.hasOnboarded {
                    OnboardingView()
                } else {
                    RootView()
                }
                #else
                if !environment.hasOnboarded {
                    OnboardingView()
                } else {
                    RootView()
                }
                #endif
            }
            .environment(environment)
            .preferredColorScheme(.dark)
            .tint(SOTheme.heatStart)
            .task {
                // StoreKit must be observed for the app's whole lifetime, or
                // renewals, refunds and Ask-to-Buy approvals are never seen.
                environment.startTransactionObserver()
                await environment.refreshSignInState()
                await environment.refreshEntitlement()
                await environment.loadScoringConfig()
                // Anything a previous session couldn't deliver goes now.
                await environment.flushPendingRuns()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    // A session can die while backgrounded; the UI must not
                    // keep claiming the user is signed in.
                    await environment.refreshSignInState()
                    await environment.refreshEntitlement()
                    await environment.flushPendingRuns()
                }
            }
        }
    }
}
