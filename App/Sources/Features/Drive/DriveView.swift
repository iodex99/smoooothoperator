import SOCore
import SOCourse
import SOGhost
import SOSync
import SOTelemetry
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    @State private var hasFirstFix = false

    var body: some View {
        ZStack {
            SOTheme.ground.ignoresSafeArea()
            if showsMap {
                DriveMapView(
                    route: polyline,
                    progress: activeProgress ?? 0,
                    follow: activeProgress != nil,
                    ghostProgress: ghostProgress,
                    ghostGapSeconds: activeGhostGap
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

    private var activeGhostGap: Double? {
        if case .active(_, _, let gap) = state { return gap }
        return nil
    }

    /// Where the rival is on the course right now. The ghost stores pace
    /// (progress vs elapsed), so its position is simply its progress at the
    /// elapsed time of this run.
    private var ghostProgress: Double? {
        guard let ghost, case .active(_, let elapsed, _) = state else { return nil }
        return ghost.progress(atElapsed: elapsed)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .calibrating:
            stateOverlay {
                VStack(spacing: 14) {
                    ChecklistView(step: state, hasFix: hasFirstFix)
                    cancelButton
                }
                .padding(24)
            }
        case .ready:
            stateOverlay {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text("READY")
                            .font(.system(size: 44, weight: .black, design: .rounded))
                            .foregroundStyle(SOTheme.heat)
                        Text("Cross the start line to begin.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        // Said BEFORE the clock exists. A fairness rule the
                        // driver only learns about afterwards is a trap.
                        Label(
                            "Roll up slowly — arriving at speed is free pace, so those runs can't rank.",
                            systemImage: "figure.walk.motion"
                        )
                        .font(.caption)
                        .foregroundStyle(SOTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .soCard(padding: 22)
                    cancelButton
                }
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
                route: polyline,
                // Mock streams are single-use, so retry is real-sensors only.
                onRetry: debugEvents == nil ? { Task { await restart() } } : nil
            ) { dismiss() }
        case .failed(let reason):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(SOTheme.caution)
                Text(failureMessage(reason))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == "location-denied" {
                    Button("Open Settings") {
                        #if canImport(UIKit)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        #endif
                    }
                    .buttonStyle(HeatButtonStyle())
                }
                Button("Back") { dismiss() }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(24)
        }
    }

    /// Always available before a run starts. Without this the pre-drive
    /// states have NO control at all: a driver who denied location, parked
    /// in a garage, or simply changed their mind can only force-quit.
    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(GhostButtonStyle())
            .accessibilityHint("Leaves the challenge without recording a run")
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
        // Location denied/restricted can never produce a run. Say so
        // immediately instead of leaving the driver on a calibration screen
        // that will never advance.
        if debugEvents == nil {
            environment.sensors.requestPermissions()
            switch environment.sensors.authorizationStatus {
            case .denied, .restricted:
                state = .failed(reason: "location-denied")
                return
            default:
                break
            }
        }
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
        // Journal the drive to disk as it happens. Best-effort on purpose:
        // if the file cannot be opened the drive still runs, because a run
        // recorded only in memory beats refusing to drive at all.
        if debugEvents == nil, let directory = environment.inFlightDirectory,
           let recorder = try? InFlightRecorder(
               directory: directory,
               courseId: courseId,
               startedAt: Date().timeIntervalSince1970,
               // Stamped now, so a crash cannot hand this drive to whoever
               // signs in next on a shared phone.
               userId: await environment.api?.userId
           ) {
            await session.attach(recorder: recorder)
        }
        let states = await session.states()
        await session.start(events: debugEvents ?? environment.sensors.start())
        // A first GPS fix is what turns "waiting" into "calibrating" on the
        // checklist — track it so the pre-flight status is real, not decor.
        if debugEvents == nil {
            startFixWatchdog()
        }
        for await newState in states {
            state = newState
            // Only ACTIVE proves fixes are arriving: the session enters
            // .calibrating unconditionally at start, so treating that as a
            // lock made the checklist claim "GPS locked" with zero fixes and
            // left the no-signal watchdog permanently disarmed.
            if case .active = newState { hasFirstFix = true }
        }
    }

    /// If no fix arrives in 45 seconds the session cannot start. Tell the
    /// driver instead of spinning forever (indoor parking, denied-then-
    /// changed permissions, hardware trouble).
    private func startFixWatchdog() {
        Task {
            try? await Task.sleep(for: .seconds(45))
            // Still not moving through the course after 45s means no usable
            // signal — say so instead of spinning forever.
            guard !hasFirstFix else { return }
            switch state {
            case .idle, .calibrating, .ready:
                state = .failed(reason: "no-gps")
            default:
                break
            }
        }
    }

    /// "TRY AGAIN" drives the same course again rather than dumping the user
    /// back on the course screen to hunt for START.
    private func restart() async {
        await session?.abort()
        session = nil
        environment.sensors.stop()
        state = .idle
        await run()
    }

    /// Never silently lose an error (spec §78) — honest, human copy.
    private func failureMessage(_ reason: String) -> String {
        switch reason {
        case "aborted":
            "Run abandoned. Your data was not submitted."
        case let message where message.contains("stream ended"):
            "Your device stopped providing sensor data. This run can't be verified."
        case "location-denied":
            environment.sensors.authorizationStatus == .restricted
                ? """
                Location is restricted on this device, so a drive can't be \
                scored. If Screen Time or a parental control is set, it has \
                to be changed there first.
                """
                : """
                Smooooth Operator needs location to score a drive. Turn it \
                on in Settings, then start the challenge again.
                """
        case "no-gps":
            """
            No GPS signal yet. Move somewhere with a clear view of the sky \
            and try again — underground and covered parking won't work.
            """
        case "course geometry invalid":
            "This course's route data is unusable. Please pick another course."
        case "scoring configuration unavailable":
            "Scoring rules couldn't be loaded. Check your connection and try again."
        default:
            // Never show a raw internal token. Anything unrecognised gets
            // human words; the code goes to the log, not the windscreen.
            "This run couldn't be completed. Please try again."
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

/// Spec §16 checklist. Reflects the ACTUAL session state — a status display
/// that never changes is worse than none, because it hides a stuck run.
struct ChecklistView: View {
    let step: DriveSessionState
    var hasFix: Bool

    private var calibrating: Bool {
        if case .calibrating = step { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("BEFORE YOU START")
                .font(.caption.weight(.black))
                .tracking(1.8)
                .foregroundStyle(SOTheme.heatStart)
            ChecklistRow(done: true, text: "Mount your phone securely")
            ChecklistRow(done: hasFix, text: hasFix
                ? "GPS locked"
                : "Waiting for GPS lock…")
            ChecklistRow(
                done: calibrating,
                text: calibrating
                    ? "Calibrating — drive straight for a few seconds when safe"
                    : "Calibration starts once you're moving"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .soCard(padding: 24)
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
                            .accessibilityLabel("Elapsed \(Int(elapsed)) seconds")
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
                        // "+2.3s" means nothing read aloud. Colour alone
                        // carries ahead/behind on screen, which is also the
                        // one thing a colourblind driver cannot see.
                        .accessibilityLabel(
                            gap <= 0
                                ? "\(abs(gap), specifier: "%.1f") seconds ahead of the ghost"
                                : "\(gap, specifier: "%.1f") seconds behind the ghost"
                        )
                }
                Button(action: onEnd) {
                    Label("End run", systemImage: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(SOTheme.textSecondary)
                        .padding(.horizontal, 20)
                        // 44pt minimum. This control is pressed in a car,
                        // sometimes by someone who has just decided to stop
                        // driving — it was 34pt, and a missed tap here is a
                        // driver looking at their phone for longer.
                        .frame(minHeight: 44)
                        .background(SOTheme.ground.opacity(0.85), in: Capsule())
                        .overlay(Capsule().strokeBorder(SOTheme.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .accessibilityLabel("End run")
                .accessibilityHint("Stops the run. Ended runs are never submitted.")
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
