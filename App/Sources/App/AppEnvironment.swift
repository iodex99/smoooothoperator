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
        struct Row: Decodable { var config: ScoringConfig }
        if let rows = try? await api.get(
            "scoring_configs?active=eq.true&select=config&limit=1", as: [Row].self
        ), let row = rows.first {
            scoringConfig = row.config
        }
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
