import CoreLocation
import SOCore
import SOCourse
import SwiftUI

/// Making a course, by driving it.
///
/// This is the only way to create one, and that is the design rather than a
/// limitation: nobody publishes a road they have never driven, the geometry
/// is real instead of sketched, and a course that is unsafe or impossible
/// cannot be made by someone who has not been down it.
///
/// The app proposes; the server decides. `validate-course` re-runs every
/// rule with the shared validator and clients are read-only on the catalog,
/// so nothing here can put bad geometry in front of another driver.
struct CreateCourseView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .briefing
    @State private var recorded: [GeoCoordinate] = []
    @State private var startedAt: Date?
    @State private var proposal: CourseBuilder.Proposal?
    @State private var issues: [CourseValidationIssue] = []
    @State private var name = ""
    @State private var visibility = Visibility.friends
    @State private var difficulty = 3
    @State private var submitting = false
    @State private var error: String?
    @State private var feedTask: Task<Void, Never>?

    enum Phase { case briefing, recording, review, done }

    enum Visibility: String, CaseIterable, Identifiable {
        case friends = "Friends"
        case publicAll = "Everyone"
        case privateOnly = "Just me"
        var id: String { rawValue }
        var wire: String {
            switch self {
            case .friends: "friends"
            case .publicAll: "public"
            case .privateOnly: "private"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SOTheme.ground.ignoresSafeArea()
                switch phase {
                case .briefing: briefing
                case .recording: recording
                case .review: review
                case .done: done
                }
            }
            .navigationTitle("Create a course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        feedTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Briefing

    private var briefing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    GlowRing(progress: 1, lineWidth: 5)
                        .frame(width: 84, height: 84)
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.title2)
                        .foregroundStyle(SOTheme.heat)
                }
                .frame(maxWidth: .infinity)

                Text("Drive the road once. That's the course.")
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 13) {
                    CreateRule(icon: "car.fill", text: "Start where you want the course to start, and stop where it should finish.")
                    CreateRule(icon: "ruler", text: "Between 1 km and 80 km. Anything shorter isn't a course.")
                    CreateRule(icon: "arrow.triangle.turn.up.right.diamond", text: "Point to point, not a lap — a course that finishes where it started can't be timed.")
                    CreateRule(icon: "shield.fill", text: "Normal, legal driving. You're mapping a road, not setting a time.")
                }
                .soCard(padding: 18)

                Text("Gates are placed for you at the start, finish and three points between. We'll check everything before it's published.")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("START RECORDING") { beginRecording() }
                    .buttonStyle(HeatButtonStyle())
            }
            .padding(22)
        }
    }

    // MARK: - Recording

    private var recording: some View {
        VStack(spacing: 22) {
            Spacer()
            // The only numbers that matter while driving, and nothing else —
            // this screen is looked at from a moving car.
            Text(DistanceFormatter.label(meters: recordedMeters))
                .font(.system(size: 44, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .accessibilityLabel("Recorded \(Int(recordedMeters)) metres")
            Text("RECORDING")
                .font(.caption.weight(.black))
                .tracking(2)
                .foregroundStyle(SOTheme.heatStart)

            if !recorded.isEmpty {
                RoutePreview(route: recorded, lineWidth: 3)
                    .frame(height: 200)
                    .padding(.horizontal, 24)
            }

            if recordedMeters < 1_000 {
                Text("Keep going — a course has to be at least 1 km.")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.textSecondary)
            }
            Spacer()

            Button("FINISH HERE") { finishRecording() }
                .buttonStyle(HeatButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .disabled(recordedMeters < 1_000)
                .opacity(recordedMeters < 1_000 ? 0.5 : 1)
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let proposal {
                    RoutePreview(route: proposal.polyline, lineWidth: 3)
                        .frame(height: 190)
                        .soCard(padding: 12)

                    HStack(spacing: 10) {
                        StatTile(label: "Distance", value: DistanceFormatter.label(meters: proposal.distanceMeters))
                        StatTile(label: "Turns", value: "\(proposal.turnCount)")
                        StatTile(label: "Gates", value: "\(proposal.checkpoints.count)")
                    }
                }

                // Every reason it cannot be published, all at once — a
                // creator should not fix one thing, resubmit, and find another.
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This road can't be a course yet", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(SOTheme.caution)
                        ForEach(issues.map(Self.explain), id: \.self) { reason in
                            Text("• \(reason)")
                                .font(.footnote)
                                .foregroundStyle(SOTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .soCard(padding: 16)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("NAME")
                        .font(.caption2.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(SOTheme.textSecondary)
                    TextField("What locals call this road", text: $name)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(SOTheme.elevated, in: RoundedRectangle(cornerRadius: 11))

                    Text("WHO CAN DRIVE IT")
                        .font(.caption2.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(SOTheme.textSecondary)
                    Picker("Visibility", selection: $visibility) {
                        ForEach(Visibility.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text("DIFFICULTY")
                        .font(.caption2.weight(.black))
                        .tracking(1.4)
                        .foregroundStyle(SOTheme.textSecondary)
                    Picker("Difficulty", selection: $difficulty) {
                        ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .soCard(padding: 16)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(SOTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(submitting ? "PUBLISHING…" : "PUBLISH COURSE") {
                    Task { await submit() }
                }
                .buttonStyle(HeatButtonStyle())
                .disabled(submitting || !issues.isEmpty || name.trimmingCharacters(in: .whitespaces).count < 3)
                .opacity(issues.isEmpty && name.trimmingCharacters(in: .whitespaces).count >= 3 ? 1 : 0.5)

                Button("Record it again") { phase = .briefing; recorded = [] }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(20)
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundStyle(SOTheme.verified)
            Text("\(name) is on the map")
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(visibility == .publicAll
                 ? "Anyone nearby can find and drive it."
                 : "It's ready whenever you are.")
                .font(.subheadline)
                .foregroundStyle(SOTheme.textSecondary)
            Spacer()
            Button("DONE") { dismiss() }
                .buttonStyle(HeatButtonStyle())
        }
        .padding(24)
    }

    // MARK: - Behaviour

    private var recordedMeters: Double {
        guard recorded.count > 1 else { return 0 }
        return zip(recorded, recorded.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private func beginRecording() {
        recorded = []
        startedAt = Date()
        phase = .recording
        feedTask = Task {
            // The same sensor feed a scored run uses. Only the fixes are
            // needed here — no orientation, no scoring, no ghost.
            for await event in environment.sensors.start() {
                if Task.isCancelled { return }
                if case .gps(let sample) = event {
                    recorded.append(sample.coordinate)
                }
            }
        }
    }

    private func finishRecording() {
        feedTask?.cancel()
        environment.sensors.stop()
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        proposal = CourseBuilder.build(from: recorded, recordedSeconds: elapsed)
        if let proposal {
            issues = CourseValidator(config: .default).validate(
                polyline: proposal.polyline,
                checkpoints: proposal.checkpoints
            )
        } else {
            issues = []
            error = "That recording didn't contain a drive. Try again with location on."
        }
        phase = .review
    }

    private func submit() async {
        guard let proposal, let api = environment.api else { return }
        submitting = true
        defer { submitting = false }
        error = nil
        do {
            _ = try await api.createCourse(
                name: name.trimmingCharacters(in: .whitespaces),
                visibility: visibility.wire,
                difficulty: difficulty,
                polyline: proposal.polyline,
                checkpoints: proposal.checkpoints
            )
            phase = .done
        } catch SupabaseAPI.APIError.http(403, _) {
            // The server gates this on Pro and re-checks on every call.
            error = "Creating courses is part of Smooooth Pro."
        } catch SupabaseAPI.APIError.http(429, _) {
            // Not a paywall — Pro already paid for this. It is a ceiling on
            // how fast the shared catalog can grow, so say that plainly
            // rather than leaving a driver to read a status code.
            error = "That's ten new courses today — the most in one day. "
                + "The road will still be there tomorrow."
        } catch {
            // The server ran the same rules; if it still said no, say what it
            // said rather than inventing a reason.
            self.error = "The server couldn't accept this course. \(error.localizedDescription)"
        }
    }

    /// Validator issues in a driver's words. The raw cases name internal
    /// concepts ("nonContiguousCheckpointSequence") that mean nothing to
    /// someone who just drove a road.
    static func explain(_ issue: CourseValidationIssue) -> String {
        switch issue {
        case .tooShort(let metres):
            "It's only \(DistanceFormatter.metric(meters: metres)) — a course has to be at least 1 km."
        case .tooLong(let metres):
            "It's \(DistanceFormatter.metric(meters: metres)) — the limit is 80 km."
        case .insufficientRoutePoints:
            "There wasn't enough of a drive to make a road from."
        case .invalidCoordinate:
            "Some of the location data was unusable. Try again with a clear view of the sky."
        case .excessivePointSpacing:
            "There's a long gap in the recording — the signal was lost for part of it."
        case .insufficientCheckpoints, .duplicateCheckpointSequence, .nonContiguousCheckpointSequence:
            "The gates couldn't be placed along this road."
        case .checkpointOffRoute:
            "A gate ended up off the road."
        case .checkpointsOutOfOrder:
            "The route doubles back on itself, so the gates can't be ordered."
        case .checkpointsTooClose:
            "Parts of this route are too close together — try a road that doesn't loop back."
        case .startNotAtRouteStart, .finishNotAtRouteEnd:
            "The start and finish need to be the two ends of the drive."
        }
    }
}

private struct CreateRule: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SOTheme.heatStart)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
