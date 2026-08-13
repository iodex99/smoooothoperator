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
            Color.black.ignoresSafeArea()
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
            VStack(spacing: 16) {
                Text("READY")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                Text("Cross the start line to begin.")
                    .foregroundStyle(.secondary)
            }
        case .active(let progress, let elapsed, let gap):
            ActiveDriveView(progress: progress, elapsed: elapsed, ghostGap: gap)
        case .processing:
            VStack(spacing: 16) {
                ProgressView()
                Text("Scoring your drive…").foregroundStyle(.secondary)
            }
        case .finished(let outcome):
            RunResultView(outcome: outcome, courseId: courseId) { dismiss() }
        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(failureMessage(reason)).multilineTextAlignment(.center)
                Button("Back") { dismiss() }
                    .buttonStyle(.bordered)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("BEFORE YOU START")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            ChecklistRow(done: true, text: "Mount your phone securely")
            ChecklistRow(
                done: false,
                text: "Calibrating — drive straight for a few seconds when safe"
            )
            ChecklistRow(done: false, text: "Waiting for GPS lock")
        }
        .padding(28)
    }
}

struct ChecklistRow: View {
    let done: Bool
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
            Text(text)
        }
    }
}

/// Spec §17: the ONLY things shown while driving.
struct ActiveDriveView: View {
    let progress: Double
    let elapsed: Double
    let ghostGap: Double?

    var body: some View {
        VStack(spacing: 28) {
            Text("CHALLENGE ACTIVE")
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(.secondary)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 96, weight: .black, design: .rounded))
                .monospacedDigit()

            ProgressView(value: progress)
                .tint(.green)
                .padding(.horizontal, 40)

            if let gap = ghostGap {
                Text(gap >= 0
                    ? "+\(gap, specifier: "%.1f")s"
                    : "\(gap, specifier: "%.1f")s")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(gap <= 0 ? .green : .orange)
            }
        }
    }
}
