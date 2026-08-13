import SOCore
import SOModels
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
    /// Drives the same course again without leaving the screen; nil in mock
    /// mode, where the synthetic stream is single-use.
    var onRetry: (() -> Void)? = nil
    let onDismiss: () -> Void

    @State private var authoritative: RunUploader.AuthoritativeResult?
    @State private var uploadError: String?
    @State private var shareImage: Image?
    @State private var savedLocally = false
    @State private var hasEnqueued = false
    /// Filled once the server has ranked the run — the single most
    /// share-worthy fact about it.
    @State private var rankText: String?

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
                    Button(onRetry == nil ? "DONE" : "TRY AGAIN") {
                        if let onRetry { onRetry() } else { onDismiss() }
                    }
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
        // The score-reveal thump (and again if the server verdict lands).
        .sensoryFeedback(.success, trigger: score)
        .task {
            renderShareCard()
            await upload()
            await loadRank()
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
        // A share with no link is a dead end for whoever receives it.
        "I scored \(score) on \(courseName) in Smooooth Operator. Beat it: https://smooooth.app"
    }

    /// Best-effort: a rank makes the card worth posting, but never blocks it.
    private func loadRank() async {
        guard let api = environment.api, let id = await api.userId else { return }
        struct Row: Decodable { var rank: Int }
        guard let rows = try? await api.get(
            "course_leaderboards?course_id=eq.\(courseId)&user_id=eq.\(id)&select=rank",
            as: [Row].self
        ), let rank = rows.first else { return }
        rankText = rank.rank == 1 ? "#1 on this course" : "#\(rank.rank) on this course"
    }

    /// Renders the share card off-screen (spec §51: the share IS the growth
    /// loop — a real card, not a text blurb).
    private func renderShareCard() {
        let renderer = ImageRenderer(content: RunShareCard(
            score: score,
            breakdown: outcome.breakdown,
            durationText: durationText,
            courseName: courseName,
            route: route,
            verdict: authoritative == nil
                ? outcome.provisionalVerdict
                : (authoritative?.verdict == "verified" ? .verified : .questionable),
            rankText: rankText
        ))
        renderer.scale = 3
        if let image = renderer.uiImage {
            shareImage = Image(uiImage: image)
        }
    }

    /// Durability first (spec §60): the drive is written to disk BEFORE any
    /// network call, so a crash, a force-quit or a dead battery during upload
    /// cannot destroy it. Only a server acknowledgement removes it.
    private func upload() async {
        guard !hasEnqueued else { return }
        hasEnqueued = true
        let pending = try? await environment.uploadQueue.enqueue(
            courseId: courseId,
            outcome: outcome,
            userId: await environment.api?.userId
        )
        savedLocally = pending != nil
        await environment.refreshPendingCount()

        guard let api = environment.api, await api.userId != nil else {
            uploadError = savedLocally
                ? "Saved on this phone. Sign in and it uploads automatically."
                // Honest about the one case where we could NOT save it.
                : "This phone couldn't save the run — check your storage."
            return
        }
        do {
            authoritative = try await RunUploader(api: api)
                .upload(outcome: outcome, courseId: courseId)
            if let pending {
                await environment.uploadQueue.acknowledge(id: pending.id)
                await environment.refreshPendingCount()
            }
        } catch {
            uploadError = savedLocally
                ? "Saved on this phone — it uploads automatically when you're back online."
                : "This run couldn't be saved or uploaded."
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

/// The image people post (spec §51).
///
/// This is the whole growth loop, so it has to survive being seen at
/// thumbnail size in a group chat: one enormous number, the course shape
/// behind it, and a verdict badge that says the score is real. It carries
/// the course name and the app's handle so a stranger can find both.
struct RunShareCard: View {
    let score: Int
    let breakdown: ScoreBreakdown
    let durationText: String
    let courseName: String
    let route: [GeoCoordinate]
    var verdict: RunVerificationStatus = .verified
    var rankText: String? = nil

    var body: some View {
        ZStack {
            // Ground + the course itself as the backdrop, not a small inset.
            SOTheme.ground
            RoutePreview(route: route, lineWidth: 7, showsGates: false)
                .opacity(0.30)
                .blur(radius: 0.4)
                .padding(.horizontal, -30)
                .padding(.vertical, 40)
            RadialGradient(
                colors: [SOTheme.heatStart.opacity(0.30), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 420
            )
            LinearGradient(
                colors: [.clear, SOTheme.ground.opacity(0.92)],
                startPoint: .center, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Wordmark(compact: true)
                    Spacer()
                    if verdict == .verified {
                        Label("VERIFIED", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1.2)
                            .foregroundStyle(SOTheme.verified)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(SOTheme.verified.opacity(0.15), in: Capsule())
                    }
                }

                Spacer(minLength: 18)

                // The number is the message.
                Text("\(score)")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, SOTheme.heatEnd],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: SOTheme.heatStart.opacity(0.55), radius: 22)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("SMOOOOTH SCORE")
                    .font(.system(size: 11, weight: .black))
                    .tracking(3.4)
                    .foregroundStyle(SOTheme.heatStart)

                if let rankText {
                    Text(rankText)
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                }

                Spacer(minLength: 16)

                // Sub-scores as bars: readable at a glance, and they show
                // WHY the number is what it is.
                VStack(spacing: 7) {
                    ShareStat(label: "PACE", bps: breakdown.paceBps)
                    ShareStat(label: "SMOOTH", bps: breakdown.smoothnessBps)
                    ShareStat(label: "CONTROL", bps: breakdown.controlBps)
                    ShareStat(label: "LEGAL", bps: breakdown.complianceBps)
                }

                Spacer(minLength: 16)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(courseName)
                            .font(.system(.headline, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(durationText)  ·  smooooth.app")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SOTheme.textSecondary)
                    }
                    Spacer()
                    Text("BEAT IT")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SOTheme.heat, in: Capsule())
                }
            }
            .padding(26)
        }
        .frame(width: 420, height: 560)
    }
}

private struct ShareStat: View {
    let label: String
    let bps: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .tracking(1.2)
                .foregroundStyle(SOTheme.textSecondary)
                .frame(width: 64, alignment: .leading)
            HeatBar(progress: Double(bps) / 10_000, height: 6)
            Text("\(bps / 100)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 26, alignment: .trailing)
        }
    }
}
