import SOCore
import SOCourse
import SOGhost
import SOSync
import SOTelemetry
import SwiftUI

/// Pre-flight checks then the minimal driving screen (spec §§16-17):
/// progress, optional ghost gap, nothing that invites interaction.
struct DriveView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let polyline: [GeoCoordinate]
    let gates: [Checkpoint]
    let benchmarkSeconds: Double
    let ghost: GhostTrajectory?
    let courseId: String
    /// Injected sensor stream for development/simulator demos (mock mode,
    /// spec §89); nil = real sensors.
    var debugEvents: AsyncStream<SensorEvent>? = nil

    @State private var session: DriveSession?
    @State private var state: DriveSessionState = .idle

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            content
        }
        .task { await run() }
        .onDisappear { Task { await session?.abort() } }
        .preferredColorScheme(.dark)
        // Keep the screen awake during an active challenge.
        .persistentSystemOverlays(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .calibrating:
            ChecklistView(step: state)
        case .ready:
            VStack(spacing: 18) {
                Text("READY")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(SOTheme.heat)
                Text("Cross the start line to begin.")
                    .foregroundStyle(SOTheme.textSecondary)
            }
        case .active(let progress, let elapsed, let gap):
            ActiveDriveView(
                route: polyline,
                progress: progress,
                elapsed: elapsed,
                ghostGap: gap
            )
        case .processing:
            VStack(spacing: 16) {
                ProgressView()
                    .tint(SOTheme.heatStart)
                Text("Scoring your drive…")
                    .foregroundStyle(SOTheme.textSecondary)
            }
        case .finished(let outcome):
            RunResultView(
                outcome: outcome,
                courseId: courseId,
                route: polyline
            ) { dismiss() }
        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(SOTheme.caution)
                Text(failureMessage(reason)).multilineTextAlignment(.center)
                Button("Back") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(24)
        }
    }

    private func run() async {
        guard let scoringConfig = environment.scoringConfig ?? loadBundledConfig() else {
            state = .failed(reason: "scoring configuration unavailable")
            return
        }
        guard let session = DriveSession(
            polyline: polyline,
            gates: gates,
            benchmarkSeconds: benchmarkSeconds,
            scoringConfig: scoringConfig,
            ghost: ghost
        ) else {
            state = .failed(reason: "course geometry invalid")
            return
        }
        self.session = session
        if debugEvents == nil {
            environment.sensors.requestPermissions()
        }
        let states = await session.states()
        await session.start(events: debugEvents ?? environment.sensors.start())
        for await newState in states {
            state = newState
        }
    }

    /// Never silently lose an error (spec §78) — honest, human copy.
    private func failureMessage(_ reason: String) -> String {
        switch reason {
        case "aborted":
            "Run abandoned. Your data was not submitted."
        case let message where message.contains("stream ended"):
            "Your device stopped providing sensor data. This run can't be verified."
        default:
            "This run couldn't be completed: \(reason)"
        }
    }

    private func loadBundledConfig() -> SOScoring.ScoringConfig? {
        guard
            let url = Bundle.main.url(forResource: "scoring-v1", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SOScoring.ScoringConfig.load(from: data)
    }
}

import SOScoring

/// Spec §16 checklist while calibrating.
struct ChecklistView: View {
    let step: DriveSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("BEFORE YOU START")
                .font(.caption.weight(.black))
                .tracking(1.8)
                .foregroundStyle(SOTheme.heatStart)
            ChecklistRow(done: true, text: "Mount your phone securely")
            ChecklistRow(
                done: false,
                text: "Calibrating — drive straight for a few seconds when safe"
            )
            ChecklistRow(done: false, text: "Waiting for GPS lock")
        }
        .soCard(padding: 24)
        .padding(24)
    }
}

struct ChecklistRow: View {
    let done: Bool
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? SOTheme.verified : SOTheme.textSecondary)
            Text(text)
                .foregroundStyle(done ? .white : SOTheme.textSecondary)
        }
    }
}

/// Spec §17: the ONLY things shown while driving. The course trace lights
/// up as you cover it — glanceable, never interactive.
struct ActiveDriveView: View {
    let route: [GeoCoordinate]
    let progress: Double
    let elapsed: Double
    let ghostGap: Double?

    var body: some View {
        ZStack {
            RoutePreview(
                route: route,
                progress: progress,
                lineWidth: 5,
                showsGates: true
            )
            .opacity(0.5)
            .padding(24)

            VStack(spacing: 26) {
                Text("CHALLENGE ACTIVE")
                    .font(.caption.weight(.black))
                    .tracking(2.4)
                    .foregroundStyle(SOTheme.heatStart)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 12)

                HeatBar(progress: progress)
                    .padding(.horizontal, 44)

                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(SOTheme.textSecondary)

                if let gap = ghostGap {
                    Text(gap >= 0
                        ? "+\(gap, specifier: "%.1f")s"
                        : "\(gap, specifier: "%.1f")s")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(gap <= 0 ? SOTheme.verified : SOTheme.caution)
                }
            }
        }
    }
}
