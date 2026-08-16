import Foundation
import SOScoring
import SOSync
import StoreKit
import SwiftUI

/// Composition root: adapters wired to Kit engines, injected via SwiftUI
/// environment. Views never construct services (spec §92: DI, no giant
/// view models).
@MainActor
@Observable
final class AppEnvironment {
    let api: SupabaseAPI?
    let sensors = SensorFeed()
    let subscriptions = StoreKitSubscriptionService()
    /// Finished runs live here until the server acknowledges them (spec §60).
    let uploadQueue: UploadQueue
    /// Where a drive is journalled while it is being driven. Nil only if the
    /// system gave us no Application Support directory at all.
    let inFlightDirectory: URL?
    var scoringConfig: ScoringConfig?
    /// Runs still owed to the server — surfaced honestly in the UI.
    var pendingRunCount = 0
    /// Runs on this phone that could not be read back. Rare, and worth
    /// admitting when it happens — the app told the driver they were safe.
    var quarantinedRunCount = 0
    /// Live Pro entitlement, refreshed at launch and on every transaction.
    var isPro = false
    /// Whether a session exists. Drives the "sign in to compete" affordances.
    var isSignedIn = false
    /// Shown once after onboarding; never nags again.
    var hasSeenSignIn: Bool {
        didSet { UserDefaults.standard.set(hasSeenSignIn, forKey: "hasSeenSignIn") }
    }
    /// The Pro offer shown once at the end of onboarding. Set the moment it
    /// is presented, not when it is dismissed, so a force-quit on the
    /// paywall cannot bring it back — an offer that reappears after being
    /// closed is the thing people uninstall apps over.
    var hasSeenIntroOffer: Bool {
        didSet { UserDefaults.standard.set(hasSeenIntroOffer, forKey: "hasSeenIntroOffer") }
    }
    /// Scored runs started today (local date), for the free-tier limit.
    private(set) var runsToday = 0
    var hasAcknowledgedSafety: Bool {
        didSet { UserDefaults.standard.set(hasAcknowledgedSafety, forKey: "safetyAcknowledged") }
    }
    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }

    init() {
        let api = SupabaseAPI.Configuration.fromBundle().map { SupabaseAPI(configuration: $0) }
        self.api = api
        // Application Support: user data that cannot be regenerated, and is
        // included in device backups. A store that fails to open falls back to
        // memory so a disk problem degrades the guarantee instead of crashing
        // the app mid-drive.
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("PendingRuns", isDirectory: true)
        let store: RunStore = directory
            .flatMap { try? FileRunStore(directory: $0) } ?? InMemoryRunStore()
        uploadQueue = UploadQueue(store: store, uploader: QueuedRunUploader(api: api))
        // Sibling of the pending-run store: drives being written *as they
        // happen*, so a crash mid-run does not destroy one.
        inFlightDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("InFlightDrives", isDirectory: true)

        hasAcknowledgedSafety = UserDefaults.standard.bool(forKey: "safetyAcknowledged")
        hasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        hasSeenSignIn = UserDefaults.standard.bool(forKey: "hasSeenSignIn")
        hasSeenIntroOffer = UserDefaults.standard.bool(forKey: "hasSeenIntroOffer")
        runsToday = Self.storedRunsToday()
    }

    // MARK: - Free tier

    private static let runCountKey = "runsToday"
    private static let runDateKey = "runsTodayDate"

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func storedRunsToday() -> Int {
        guard UserDefaults.standard.string(forKey: runDateKey) == todayKey() else { return 0 }
        return UserDefaults.standard.integer(forKey: runCountKey)
    }

    /// Whether another run may start now (spec §§8, 74).
    var canStartRun: Bool {
        DailyRunAllowance.allows(runsToday: runsToday, isPro: isPro)
    }

    /// nil = unlimited.
    var runsRemainingToday: Int? {
        DailyRunAllowance.remaining(runsToday: runsToday, isPro: isPro)
    }

    func recordRunStarted() {
        runsToday = Self.storedRunsToday() + 1
        UserDefaults.standard.set(runsToday, forKey: Self.runCountKey)
        UserDefaults.standard.set(Self.todayKey(), forKey: Self.runDateKey)
    }

    /// Onboarding ends with the safety gate — both stick together.
    func completeOnboarding() {
        hasAcknowledgedSafety = true
        hasOnboarded = true
    }

    /// Erases everything about a driver that lives on this phone.
    ///
    /// Called when an account is deleted, because the app tells the driver
    /// "your account and all its data have been deleted" and that sentence
    /// has to be true. The server row goes; so must the runs still queued
    /// here and any half-finished drive journalled to disk. Their GPS traces
    /// must not outlive the account that recorded them.
    func purgeLocalData(for userId: String) async {
        await uploadQueue.purge(userId: userId)
        if let directory = inFlightDirectory {
            InFlightRecorder.discardAll(in: directory)
        }
        await refreshPendingCount()
    }

    /// The scoring config shipped in the bundle, for when the server's has
    /// not loaded yet. Shared with DriveView so a recovered drive and a live
    /// one are scored against the same rules.
    static func bundledScoringConfig() -> SOScoring.ScoringConfig? {
        guard let url = Bundle.main.url(forResource: "scoring-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? SOScoring.ScoringConfig.load(from: data)
    }

    /// Picks up drives that were journalled but never made it to the upload
    /// queue — the app was killed mid-run, or crashed between finishing and
    /// enqueueing.
    ///
    /// Without this the recorder writes files nobody ever reads: the drive
    /// is preserved on disk and then orphaned forever, which is the feature
    /// doing nothing at all while looking like it works.
    func recoverInterruptedDrives() async {
        guard let directory = inFlightDirectory else { return }
        let recovered = InFlightRecorder.recover(in: directory)
        guard !recovered.isEmpty else { return }
        let currentUserId = await api?.userId
        for drive in recovered {
            // One device, two drivers. A journal belonging to someone else is
            // left exactly where it is — not uploaded, and not deleted, since
            // its owner may sign back in on this phone. The upload queue
            // already works this way; the journal now matches it rather than
            // handing one driver's GPS trace to another driver's account.
            guard drive.belongs(to: currentUserId) else { continue }

            // A recovered drive is not special — it goes through the same
            // evaluation pipeline as any other, and the server rescores it
            // afterwards like any other. The only difference is that it took
            // a longer route to the queue.
            //
            // Discarded either way: a journal that fails to become a run is
            // rubbish, and leaving it would re-offer the same failure on
            // every launch forever.
            defer { InFlightRecorder.discard(drive, in: directory) }

            guard let api,
                  let route = try? await api.courseRoute(courseId: drive.courseId),
                  let config = scoringConfig ?? Self.bundledScoringConfig()
            else { continue }

            // The course's OWN benchmark, not a placeholder. Pace is 35% of
            // the score and is measured against this number — scoring a
            // recovered run against a hardcoded 300 s would show the driver
            // a provisional score for a course they did not drive.
            struct BenchmarkRow: Decodable { var benchmark_seconds: Double? }
            let benchmark = (try? await api.get(
                "courses?id=eq.\(drive.courseId)&select=benchmark_seconds",
                as: [BenchmarkRow].self
            ))?.first?.benchmark_seconds ?? 0

            // An interrupted drive often never reached the finish gate, in
            // which case there is genuinely no run to recover and the
            // pipeline says so by returning nil.
            guard let outcome = RunEvaluationPipeline.evaluate(
                gps: drive.gps,
                imu: drive.imu,
                route: route.polyline,
                gates: route.gates,
                benchmarkSeconds: benchmark,
                scoringConfig: config
            ) else { continue }

            _ = try? await uploadQueue.enqueue(
                courseId: drive.courseId,
                outcome: DriveRunOutcome(
                    evaluation: outcome, rawGPS: drive.gps, rawIMU: drive.imu
                ),
                userId: currentUserId
            )
        }
        await refreshPendingCount()
    }

    /// Loads the active scoring config from the server (clients score
    /// provisionally with the same config the server scores with).
    func loadScoringConfig() async {
        guard let api else { return }
        // Route the server row through ScoringConfig.load, which rejects
        // structurally invalid configs. Decoding it raw let a malformed row
        // reach the scoring engine — the audit found that path could crash
        // every client at the end of every drive.
        struct Row: Decodable { var config: ScoringConfig }
        guard let rows = try? await api.get(
            "scoring_configs?active=eq.true&select=config&limit=1", as: [Row].self
        ), let row = rows.first else { return }
        guard
            let data = try? JSONEncoder().encode(row.config),
            let validated = try? ScoringConfig.load(from: data)
        else { return }
        scoringConfig = validated
    }

    /// Drains the offline queue and refreshes the badge. Safe to call often:
    /// the queue ignores overlapping flushes and honors per-run backoff.
    func flushPendingRuns() async {
        let summary = await uploadQueue.flush(currentUserId: await api?.userId)
        pendingRunCount = summary.remaining
    }

    /// The badge must count only what THIS account can actually upload —
    /// another driver's queued runs are none of its business.
    func refreshPendingCount(forCurrentUser: Bool = true) async {
        let me = await api?.userId
        let runs = (try? await uploadQueue.pending()) ?? []
        pendingRunCount = runs.filter { $0.userId == nil || $0.userId == me }.count
        // A run whose file could not be decoded is moved aside so the queue
        // keeps draining. That is the right behaviour, but it was silent:
        // the result screen had already promised "saved on this phone", and
        // a quarantined run will never upload. Say so instead.
        quarantinedRunCount = await uploadQueue.quarantinedCount()
    }

    // MARK: - Account

    func signIn(identityToken: String, nonce: String) async throws {
        guard let api else { throw SupabaseAPI.APIError.notConfigured }
        try await api.signInWithApple(identityToken: identityToken, nonce: nonce)
        isSignedIn = await api.isSignedIn
        hasSeenSignIn = true
        // Anything recorded while signed out goes up now.
        await flushPendingRuns()
        // A subscription bought before signing in belongs to this account.
        await claimSubscriptionIfNeeded()
    }

    /// Completes a provider (Google) sign-in from the OAuth callback.
    func completeOAuth(callbackURL: URL) async throws {
        guard let api else { throw SupabaseAPI.APIError.notConfigured }
        try await api.completeOAuth(callbackURL: callbackURL)
        isSignedIn = await api.isSignedIn
        hasSeenSignIn = true
        await flushPendingRuns()
    }

    func signOut() async {
        await api?.signOut()
        isSignedIn = false
        isPro = false
        // The next account must not inherit this one's free-run count, and
        // must not be shown a queue badge for runs it can never upload.
        runsToday = 0
        UserDefaults.standard.removeObject(forKey: Self.runCountKey)
        await refreshPendingCount(forCurrentUser: true)
    }

    func refreshSignInState() async {
        isSignedIn = await api?.isSignedIn ?? false
    }

    /// Purchases with the signed-in user's id attached, so Apple's webhook
    /// can attribute the subscription to them. A purchase made signed out is
    /// still honoured locally and claimed on the server after sign-in.
    func purchase(_ product: Product) async -> StoreKitSubscriptionService.PurchaseOutcome {
        let token = await api?.userId.flatMap(UUID.init(uuidString:))
        let outcome = await subscriptions.purchase(product, appAccountToken: token)
        if case .success = outcome {
            await claimSubscriptionIfNeeded()
        }
        return outcome
    }

    /// Adopts a server-side subscription row that arrived unattributed
    /// (promo code, another device, or a purchase made before signing in).
    /// The RPC only ever claims rows nobody owns.
    func claimSubscriptionIfNeeded() async {
        guard let api, await api.userId != nil,
              let original = await subscriptions.currentOriginalTransactionId()
        else { return }
        _ = try? await api.rpc(
            "claim_subscription",
            json: ["p_original_transaction_id": original]
        )
    }

    /// Entitlement refresh (launch, foreground, and after any transaction).
    func refreshEntitlement() async {
        isPro = await subscriptions.hasPro()
    }

    /// Observes StoreKit for the entire app lifetime: renewals, refunds,
    /// Ask-to-Buy approvals, promo codes and purchases made on another
    /// device all arrive here and nowhere else.
    func startTransactionObserver() {
        subscriptions.startObserving { [weak self] in
            Task { @MainActor in await self?.refreshEntitlement() }
        }
    }
}
