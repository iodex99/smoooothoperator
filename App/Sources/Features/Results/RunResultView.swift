import SOCore
import SOScoring
import SOSync
import SwiftUI
import UIKit

/// The moment that drives retention (spec §§50, 97): score reveal, verdict,
/// share card, and the immediate reason to go again.
struct RunResultView: View {
    @Environment(AppEnvironment.self) private var environment

    let outcome: DriveRunOutcome
    let courseId: String
    let route: [GeoCoordinate]
    let onDismiss: () -> Void

    @State private var authoritative: RunUploader.AuthoritativeResult?
    @State private var uploadError: String?
    @State private var shareImage: Image?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(verdictTitle)
                    .font(.caption.weight(.black))
                    .tracking(2)
                    .foregroundStyle(verdictColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(verdictColor.opacity(0.13), in: Capsule())

                ZStack {
                    GlowRing(progress: Double(score) / 10_000)
                        .frame(width: 216, height: 216)
                    VStack(spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 58, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text(authoritative == nil ? "PROVISIONAL" : "SERVER VERIFIED")
                            .font(.caption2.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(
                                authoritative == nil ? SOTheme.textSecondary : SOTheme.verified
                            )
                    }
                }

                if authoritative == nil && uploadError == nil {
                    Label("Verifying with the server…", systemImage: "icloud.and.arrow.up")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.textSecondary)
                }
                if let uploadError {
                    // Spec §78: stored locally, never lost.
                    Label(uploadError, systemImage: "externaldrive.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.caution)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    ScoreBarRow(label: "Pace", bps: outcome.breakdown.paceBps)
                    ScoreBarRow(label: "Smoothness", bps: outcome.breakdown.smoothnessBps)
                    ScoreBarRow(label: "Control", bps: outcome.breakdown.controlBps)
                    ScoreBarRow(label: "Legal", bps: outcome.breakdown.complianceBps)
                }
                .soCard(padding: 18)

                HStack(spacing: 10) {
                    SOChip(icon: "timer", text: durationText)
                    SOChip(icon: "point.topleft.down.curvedto.point.bottomright.up", text: courseName)
                    Spacer()
                }

                VStack(spacing: 12) {
                    Button("TRY AGAIN") { onDismiss() }
                        .buttonStyle(HeatButtonStyle())

                    if let shareImage {
                        ShareLink(
                            item: shareImage,
                            preview: SharePreview("My Smooooth run", image: shareImage)
                        ) {
                            Label("Share run card", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GhostButtonStyle())
                    } else {
                        ShareLink(item: shareText) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .padding(24)
        }
        .background(SOTheme.ground)
        .task {
            renderShareCard()
            await upload()
            renderShareCard()
        }
    }

    private var score: Int {
        authoritative?.score ?? outcome.provisionalScore
    }

    /// Course display names come from the server feed; the demo course is
    /// the only offline case.
    private var courseName: String {
        courseId == "demo" ? "Malibu #042" : courseId
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
        case .verified: SOTheme.verified
        case .questionable: SOTheme.caution
        case .invalid: SOTheme.danger
        }
    }

    private var durationText: String {
        Duration.seconds(outcome.durationSeconds)
            .formatted(.time(pattern: .minuteSecond))
    }

    private var shareText: String {
        "I scored \(score) on Smooooth Operator. Think you can beat me?"
    }

    /// Renders the share card off-screen (spec §51: the share IS the growth
    /// loop — a real card, not a text blurb).
    private func renderShareCard() {
        let renderer = ImageRenderer(content: RunShareCard(
            score: score,
            breakdown: outcome.breakdown,
            durationText: durationText,
            courseName: courseName,
            route: route
        ))
        renderer.scale = 3
        if let image = renderer.uiImage {
            shareImage = Image(uiImage: image)
        }
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

struct ScoreBarRow: View {
    let label: String
    let bps: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(SOTheme.textSecondary)
                .frame(width: 104, alignment: .leading)
            HeatBar(progress: Double(bps) / 10_000)
            Text("\(bps / 100).\(bps % 100 / 10)")
                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

/// The image people post (spec §51) — score, trace, wordmark. Rendered via
/// ImageRenderer at 3×; never shows raw location, only the course shape.
struct RunShareCard: View {
    let score: Int
    let breakdown: ScoreBreakdown
    let durationText: String
    let courseName: String
    let route: [GeoCoordinate]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Wordmark(compact: true)
                Spacer()
                Text(durationText)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(SOTheme.textSecondary)
            }

            RoutePreview(route: route, lineWidth: 3)
                .frame(height: 130)

            VStack(alignment: .leading, spacing: 0) {
                Text("SMOOOOTH SCORE")
                    .font(.caption2.weight(.black))
                    .tracking(2)
                    .foregroundStyle(SOTheme.heatStart)
                Text("\(score)")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }

            HStack(spacing: 0) {
                ShareStat(label: "PACE", bps: breakdown.paceBps)
                ShareStat(label: "SMOOTH", bps: breakdown.smoothnessBps)
                ShareStat(label: "CONTROL", bps: breakdown.controlBps)
                ShareStat(label: "LEGAL", bps: breakdown.complianceBps)
            }

            HStack {
                Text(courseName)
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Think you can beat me?")
                    .font(.footnote)
                    .foregroundStyle(SOTheme.textSecondary)
            }
        }
        .padding(22)
        .frame(width: 340)
        .background {
            ZStack {
                SOTheme.ground
                RadialGradient(
                    colors: [SOTheme.heatStart.opacity(0.14), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 320
                )
            }
        }
    }
}

private struct ShareStat: View {
    let label: String
    let bps: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .black))
                .tracking(1)
                .foregroundStyle(SOTheme.textSecondary)
            Text("\(bps / 100).\(bps % 100 / 10)")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}
