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
    var scoringConfig: ScoringConfig?
    var hasAcknowledgedSafety: Bool {
        didSet { UserDefaults.standard.set(hasAcknowledgedSafety, forKey: "safetyAcknowledged") }
    }

    init() {
        api = SupabaseAPI.Configuration.fromBundle().map { SupabaseAPI(configuration: $0) }
        hasAcknowledgedSafety = UserDefaults.standard.bool(forKey: "safetyAcknowledged")
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
}
