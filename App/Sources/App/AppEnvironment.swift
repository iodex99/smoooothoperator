import Foundation
import SOScoring
import SOSync
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
        let summary = await uploadQueue.flush()
        pendingRunCount = summary.remaining
    }

    func refreshPendingCount() async {
        pendingRunCount = (try? await uploadQueue.pendingCount()) ?? 0
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
