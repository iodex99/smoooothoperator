import SOCore
import SOCourse
import SOGhost
import SOSync
import SOTelemetry
import SwiftUI

/// Pre-flight checks then the driving screen (spec §§16-17): the glanceable
/// map with the next turns (user directive 2026-08-13), progress, optional
/// ghost gap. Nothing invites interaction while moving; the only control is
/// an explicit end-run escape hatch behind a confirmation.
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
    @State private var confirmEnd = false

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            if showsMap {
                DriveMapView(
                    route: polyline,
                    progress: activeProgress ?? 0,
                    follow: activeProgress != nil
                )
                .ignoresSafeArea()
            }
            content
        }
        .task { await run() }
        .onDisappear { Task { await session?.abort() } }
        .preferredColorScheme(.dark)
        // Keep the screen awake during an active challenge.
        .persistentSystemOverlays(.hidden)
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End run", role: .destructive) {
                Task { await session?.abort() }
                dismiss()
            }
            Button("Keep driving", role: .cancel) {}
        } message: {
            Text("Ended runs are never submitted. Only do this once you're safely stopped.")
        }
    }

    private var showsMap: Bool {
        switch state {
        case .idle, .calibrating, .ready, .active: true
        default: false
        }
    }

    private var activeProgress: Double? {
        if case .active(let progress, _, _) = state { return progress }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .calibrating:
            stateOverlay {
                ChecklistView(step: state)
            }
        case .ready:
            stateOverlay {
                VStack(spacing: 8) {
                    Text("READY")
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(SOTheme.heat)
                    Text("Cross the start line to begin.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .soCard(padding: 22)
                .padding(24)
            }
        case .active(let progress, let elapsed, let gap):
            ActiveDriveOverlay(
                progress: progress,
                elapsed: elapsed,
                ghostGap: gap
            ) { confirmEnd = true }
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

    /// Pre-drive overlays sit at the bottom over a dimmed course map.
    private func stateOverlay<Overlay: View>(@ViewBuilder overlay: () -> Overlay) -> some View {
        VStack {
            Spacer()
            overlay()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, SOTheme.ground.opacity(0.9)],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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

/// Spec §17: what's shown while driving — progress, time, ghost gap, and
/// the map underneath. Every element is glanceable; the single control is
/// the end-run hatch, deliberately small and confirmed.
struct ActiveDriveOverlay: View {
    let progress: Double
    let elapsed: Double
    let ghostGap: Double?
    let onEnd: () -> Void

    var body: some View {
        VStack {
            // Top: progress + time on a scrim, readable over any map.
            VStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 8)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("CHALLENGE ACTIVE")
                            .font(.caption2.weight(.black))
                            .tracking(1.6)
                            .foregroundStyle(SOTheme.heatStart)
                        Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.8), radius: 6)
                    }
                }
                HeatBar(progress: progress)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
            .background(
                LinearGradient(
                    colors: [SOTheme.ground.opacity(0.92), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            )

            Spacer()

            // Bottom: ghost gap + the end-run hatch.
            VStack(spacing: 14) {
                if let gap = ghostGap {
                    Text(gap >= 0
                        ? "+\(gap, specifier: "%.1f")s"
                        : "\(gap, specifier: "%.1f")s")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(gap <= 0 ? SOTheme.verified : SOTheme.caution)
                        .shadow(color: .black.opacity(0.8), radius: 8)
                }
                Button(action: onEnd) {
                    Label("End run", systemImage: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(SOTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(SOTheme.ground.opacity(0.85), in: Capsule())
                        .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
                }
            }
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.clear, SOTheme.ground.opacity(0.9)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}
