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
    var scoringConfig: ScoringConfig?
    /// Runs still owed to the server — surfaced honestly in the UI.
    var pendingRunCount = 0
    /// Live Pro entitlement, refreshed at launch and on every transaction.
    var isPro = false
    /// Whether a session exists. Drives the "sign in to compete" affordances.
    var isSignedIn = false
    /// Shown once after onboarding; never nags again.
    var hasSeenSignIn: Bool {
        didSet { UserDefaults.standard.set(hasSeenSignIn, forKey: "hasSeenSignIn") }
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

        hasAcknowledgedSafety = UserDefaults.standard.bool(forKey: "safetyAcknowledged")
        hasOnboarded = UserDefaults.standard.bool(forKey: "hasOnboarded")
        hasSeenSignIn = UserDefaults.standard.bool(forKey: "hasSeenSignIn")
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
