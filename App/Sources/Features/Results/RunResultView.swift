import SOCore
import SOIntegrity
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
    @State private var resolvedCourseName: String?

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

                // The card IS the result. Showing the score in one design
                // here and a different one behind a "share" button meant
                // most drivers never discovered the card at all.
                ScaledShareCard(card: shareCard)
                    .padding(.horizontal, 2)

                Text(authoritative == nil ? "PROVISIONAL — THE SERVER RESCORES EVERY RUN" : "SERVER VERIFIED")
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(
                        authoritative == nil ? SOTheme.textSecondary : SOTheme.verified
                    )
                    .multilineTextAlignment(.center)

                if authoritative == nil && uploadError == nil {
                    Label("Verifying with the server…", systemImage: "icloud.and.arrow.up")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.textSecondary)
                }
                if flyingStart {
                    Label(
                        "You crossed the start line already at speed. Roll up slowly next time and this run ranks.",
                        systemImage: "figure.walk.motion"
                    )
                    .font(.footnote)
                    .foregroundStyle(SOTheme.caution)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let uploadError {
                    // Spec §78: stored locally, never lost.
                    Label(uploadError, systemImage: "externaldrive.badge.checkmark")
                        .font(.footnote)
                        .foregroundStyle(SOTheme.caution)
                        .multilineTextAlignment(.center)
                }

                // Sharing is the growth loop and the card is already on
                // screen, so it leads. Leaving is one tap away underneath.
                VStack(spacing: 12) {
                    if let shareImage {
                        ShareLink(
                            item: shareImage,
                            preview: SharePreview("My Smooooth run", image: shareImage)
                        ) {
                            Label("SHARE THIS CARD", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HeatButtonStyle())
                    } else {
                        ShareLink(item: shareText) {
                            Label("SHARE", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HeatButtonStyle())
                    }

                    Button(onRetry == nil ? "Done" : "Try again") {
                        if let onRetry { onRetry() } else { onDismiss() }
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(24)
        }
        .background(SOTheme.ground)
        // The score-reveal thump (and again if the server verdict lands).
        .sensoryFeedback(.success, trigger: score)
        .task {
            renderShareCard()
            await loadCourseName()
            await upload()
            await loadRank()
            renderShareCard()
        }
    }

    private var score: Int {
        authoritative?.score ?? outcome.provisionalScore
    }

    /// Never show a UUID to a human — the share card is the growth loop and
    /// "I scored 8123 on 3f2a1b9c-4d5e…" kills it. Falls back to a neutral
    /// word until the name arrives.
    private var courseName: String {
        if courseId == "demo" { return "Malibu #042" }
        return resolvedCourseName ?? "this course"
    }

    private func loadCourseName() async {
        guard let api = environment.api, courseId != "demo" else { return }
        struct Row: Decodable { var name: String }
        if let rows = try? await api.get(
            "courses?id=eq.\(courseId)&select=name", as: [Row].self
        ), let row = rows.first {
            resolvedCourseName = row.name
        }
    }

    /// The one "not ranked" reason a driver can actually act on next time.
    private var flyingStart: Bool {
        outcome.integrityFlags.contains(IntegrityFlag.flyingStart.rawValue)
    }

    private var verdictTitle: String {
        switch outcome.provisionalVerdict {
        case .verified: "RUN COMPLETE"
        case .questionable: flyingStart ? "FLYING START — NOT RANKED" : "RUN COMPLETE — NOT RANKED"
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

    /// The single definition of the card, used both for what is shown on
    /// this screen and for what is exported — they cannot drift apart.
    private var shareCard: RunShareCard {
        RunShareCard(
            score: score,
            breakdown: outcome.breakdown,
            durationText: durationText,
            courseName: courseName,
            route: route,
            verdict: authoritative == nil
                ? outcome.provisionalVerdict
                : (authoritative?.verdict == "verified" ? .verified : .questionable),
            rankText: rankText
        )
    }

    /// Renders the card off-screen for the share sheet (spec §51: the share
    /// IS the growth loop — a real image, not a text blurb).
    private func renderShareCard() {
        let renderer = ImageRenderer(content: shareCard)
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

/// The artifact that leaves the app (spec §51). Shown full-size on the
/// result screen and exported byte-for-byte identical by ImageRenderer —
/// a driver must never have to tap "share" to discover what they'd be
/// sharing.
///
/// The road is the hero. A score is a number anyone could type; the shape
/// of the road you drove is the one thing on this card nobody else has.
struct RunShareCard: View {
    let score: Int
    let breakdown: ScoreBreakdown
    let durationText: String
    let courseName: String
    let route: [GeoCoordinate]
    var verdict: RunVerificationStatus = .verified
    var rankText: String? = nil

    /// Fixed so the on-screen card and the exported image are the same
    /// composition at different scales, never two different layouts.
    static let size = CGSize(width: 420, height: 560)

    var body: some View {
        ZStack(alignment: .topLeading) {
            SOTheme.ground

            // Heat bloom from the top-right, as if the road were lit.
            RadialGradient(
                colors: [SOTheme.heatStart.opacity(0.22), .clear],
                center: .init(x: 0.85, y: 0.12), startRadius: 0, endRadius: 340
            )

            // The route, at full strength and full bleed — this is the
            // subject of the card, not a watermark behind it.
            RoutePreview(route: route, lineWidth: 6, showsGates: true)
                .padding(.horizontal, 34)
                .padding(.top, 74)
                .padding(.bottom, 236)
                .shadow(color: SOTheme.heatStart.opacity(0.45), radius: 26)

            // Scrim so the numbers stay legible wherever the road wanders.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.34),
                    .init(color: SOTheme.ground.opacity(0.86), location: 0.56),
                    .init(color: SOTheme.ground, location: 0.68),
                ],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Wordmark(compact: true)
                    Spacer()
                    verdictBadge
                }

                Spacer(minLength: 0)

                // Score and elapsed time share a baseline: the two numbers
                // a driver is actually judged on.
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(score)")
                            .font(.system(size: 88, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, SOTheme.heatEnd],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .shadow(color: SOTheme.heatStart.opacity(0.6), radius: 24)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("SMOOOOTH SCORE")
                            .font(.system(size: 10, weight: .black))
                            .tracking(3.2)
                            .foregroundStyle(SOTheme.heatStart)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(durationText)
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                        Text("ELAPSED")
                            .font(.system(size: 10, weight: .black))
                            .tracking(3.2)
                            .foregroundStyle(SOTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }

                if let rankText {
                    Text(rankText)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.top, 12)
                }

                // The four disciplines, as a strip rather than four stacked
                // bars — same information, far less of the card spent on it.
                HStack(alignment: .top, spacing: 12) {
                    ShareStat(label: "PACE", bps: breakdown.paceBps)
                    ShareStat(label: "SMOOTH", bps: breakdown.smoothnessBps)
                    ShareStat(label: "CONTROL", bps: breakdown.controlBps)
                    ShareStat(label: "LEGAL", bps: breakdown.complianceBps)
                }
                .padding(.top, 20)

                Spacer(minLength: 18)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(courseName)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("smooooth.app")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SOTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text("BEAT IT")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(SOTheme.heat, in: Capsule())
                        .shadow(color: SOTheme.heatStart.opacity(0.5), radius: 12, y: 4)
                }
            }
            .padding(26)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// Honest either way. A card that simply omitted the badge on an
    /// unranked run would read as a verified one to anyone who saw it.
    @ViewBuilder
    private var verdictBadge: some View {
        switch verdict {
        case .verified:
            badge("VERIFIED", icon: "checkmark.seal.fill", tint: SOTheme.verified)
        case .questionable:
            badge("NOT RANKED", icon: "exclamationmark.circle.fill", tint: SOTheme.caution)
        case .invalid:
            badge("NOT ELIGIBLE", icon: "xmark.circle.fill", tint: SOTheme.danger)
        }
    }

    private func badge(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .black))
            .tracking(1.2)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// One discipline, as a column. `fixedSize` is load-bearing: at 26pt wide
/// "100" wrapped to two lines on the rendered card, which CI caught.
private struct ShareStat: View {
    let label: String
    let bps: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .black))
                .tracking(1.1)
                .foregroundStyle(SOTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Text("\(bps / 100)")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            HeatBar(progress: Double(bps) / 10_000, height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The share card at whatever width it is given, scaled as one piece so the
/// on-screen preview and the exported PNG are the same composition.
struct ScaledShareCard: View {
    let card: RunShareCard

    var body: some View {
        Color.clear
            .aspectRatio(
                RunShareCard.size.width / RunShareCard.size.height,
                contentMode: .fit
            )
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    card.scaleEffect(
                        proxy.size.width / RunShareCard.size.width,
                        anchor: .topLeading
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(SOTheme.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 26, y: 12)
    }
}
