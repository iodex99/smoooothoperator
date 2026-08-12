import SwiftUI
import SOCore

/// App entry point. Deliberately minimal: all logic lives in SmoooothKit;
/// this layer is adapters + layout only (ADR-0001).
@main
struct SmoooothOperatorApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchPlaceholderView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Placeholder until Feature views land (M3). Proves the app target links
/// against the Kit.
struct LaunchPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("SMOOOOTH OPERATOR")
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .tracking(2)
            Text("Drive smooth. Finish fast.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Kit \(KitInfo.version)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}
