import SOSync
import SwiftUI

/// The moment that drives retention (spec §§50, 97): score, verdict, and
/// the immediate reasons to go again.
struct RunResultView: View {
    @Environment(AppEnvironment.self) private var environment

    let outcome: DriveRunOutcome
    let courseId: String
    let onDismiss: () -> Void

    @State private var authoritative: RunUploader.AuthoritativeResult?
    @State private var uploadError: String?

    var body: some View {
        VStack(spacing: 22) {
            Text(verdictTitle)
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundStyle(verdictColor)

            Text("\(authoritative?.score ?? outcome.provisionalScore)")
                .font(.system(size: 88, weight: .black, design: .rounded))
                .monospacedDigit()

            if authoritative == nil && uploadError == nil {
                Label("Verifying with the server…", systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let uploadError {
                // Spec §78: stored locally, never lost.
                Label(uploadError, systemImage: "externaldrive.badge.checkmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Grid(horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    ScorePill(label: "Pace", bps: outcome.breakdown.paceBps)
                    ScorePill(label: "Smooth", bps: outcome.breakdown.smoothnessBps)
                }
                GridRow {
                    ScorePill(label: "Control", bps: outcome.breakdown.controlBps)
                    ScorePill(label: "Legal", bps: outcome.breakdown.complianceBps)
                }
            }

            Text(durationText)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                Button {
                    onDismiss()
                } label: {
                    Text("TRY AGAIN")
                        .font(.headline.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .task { await upload() }
    }

    private var verdictTitle: String {
        switch outcome.provisionalVerdict {
        case .verified: "RUN COMPLETE"
        case .questionable: "RUN COMPLETE — NOT RANKED"
        case .invalid: outcome.deviationDetected
            ? "LEFT THE COURSE — NOT RANKED"
            : "RUN NOT ELIGIBLE"
        }
    }

    private var verdictColor: Color {
        switch outcome.provisionalVerdict {
        case .verified: .green
        case .questionable: .orange
        case .invalid: .red
        }
    }

    private var durationText: String {
        Duration.seconds(outcome.durationSeconds)
            .formatted(.time(pattern: .minuteSecond))
    }

    private var shareText: String {
        "I scored \(authoritative?.score ?? outcome.provisionalScore) on Smooooth Operator. Think you can beat me?"
    }

    private func upload() async {
        guard let api = environment.api else {
            uploadError = "Run stored on this phone — connect an account to compete."
            return
        }
        do {
            authoritative = try await RunUploader(api: api)
                .upload(outcome: outcome, courseId: courseId)
        } catch {
            uploadError = "Your run is safely stored and will upload when you're connected."
        }
    }
}

struct ScorePill: View {
    let label: String
    let bps: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text("\(bps / 100).\(bps % 100 / 10)")
                .font(.headline.monospacedDigit())
        }
        .frame(minWidth: 70)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quinary, in: Capsule())
    }
}
