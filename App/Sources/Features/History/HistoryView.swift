import SwiftUI

/// Your runs (spec §§13, 50). The app recorded every drive and had nowhere
/// to show them — a competitive app where you cannot review your own record
/// is missing its memory.
struct HistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var state: LoadState = .loading

    enum LoadState {
        case loading
        case ready([Run])
        case failed(String)
    }

    struct Run: Identifiable, Decodable {
        var id: String
        var score: Int?
        var clientScore: Int?
        var verification: String?
        var durationSeconds: Double?
        var createdAt: String
        var courses: CourseRef?

        struct CourseRef: Decodable {
            var name: String
        }

        enum CodingKeys: String, CodingKey {
            case id, score, verification, courses
            case clientScore = "client_score"
            case durationSeconds = "duration_seconds"
            case createdAt = "created_at"
        }

        /// The server's score when it exists; otherwise the phone's estimate,
        /// clearly labelled as such.
        var displayScore: Int? { score ?? clientScore }
        var isProvisional: Bool { score == nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch state {
                case .loading:
                    ProgressView()
                        .tint(SOTheme.heatStart)
                        .frame(maxWidth: .infinity, minHeight: 260)
                case .ready(let runs) where runs.isEmpty:
                    VStack(spacing: 14) {
                        ZStack {
                            GlowRing(progress: 1, lineWidth: 5)
                                .frame(width: 88, height: 88)
                            Image(systemName: "flag.checkered")
                                .font(.system(size: 30))
                                .foregroundStyle(SOTheme.heat)
                        }
                        .accessibilityHidden(true)
                        Text("No runs yet")
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                        Text("Drive today's challenge and it lands here.")
                            .font(.subheadline)
                            .foregroundStyle(SOTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                case .ready(let runs):
                    ForEach(runs) { run in
                        HistoryRow(run: run)
                    }
                case .failed(let message):
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(SOTheme.caution)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(SOTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .padding(18)
        }
        .background(SOTheme.ground)
        .navigationTitle("Your runs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let api = environment.api, await api.userId != nil else {
            state = .failed("Sign in to see your runs.")
            return
        }
        do {
            // Embedded course name in one round trip; RLS already restricts
            // this to the caller's own runs.
            let runs = try await api.get(
                "runs?select=id,score,client_score,verification,duration_seconds,created_at,courses(name)"
                    + "&order=created_at.desc&limit=100",
                as: [Run].self
            )
            state = .ready(runs)
        } catch {
            state = .failed("Couldn't load your runs. Check your connection and try again.")
        }
    }
}

struct HistoryRow: View {
    let run: HistoryView.Run

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.courses?.name ?? "Course")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text(dateText)
                    if let duration = run.durationSeconds {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(SOTheme.textSecondary)
                verdictBadge
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(run.displayScore.map(String.init) ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if run.isProvisional {
                    Text("PROVISIONAL")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(SOTheme.textSecondary)
                }
            }
        }
        .soCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var verdictBadge: some View {
        switch run.verification {
        case "verified":
            Label("Verified", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SOTheme.verified)
        case "questionable":
            Label("Not ranked", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SOTheme.caution)
        case "invalid":
            Label("Not eligible", systemImage: "xmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SOTheme.danger)
        default:
            Label("Awaiting verification", systemImage: "clock")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SOTheme.textSecondary)
        }
    }

    private var dateText: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: run.createdAt)
            ?? ISO8601DateFormatter().date(from: run.createdAt)
        guard let date else { return "" }
        return date.formatted(.dateTime.day().month().hour().minute())
    }
}
