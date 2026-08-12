import Foundation
import SOSync
import StoreKit

/// StoreKit 2 implementation of the Kit's entitlement seam (spec §73).
/// Prices always come from the App Store products — never hard-coded.
final class StoreKitSubscriptionService: SubscriptionProviding, @unchecked Sendable {
    static let productIds = [
        "smooooth.pro.weekly",
        "smooooth.pro.monthly",
        "smooooth.pro.yearly",
    ]

    func products() async throws -> [Product] {
        try await Product.products(for: Self.productIds)
    }

    func hasPro() async -> Bool {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if Self.productIds.contains(transaction.productID),
               transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    /// Purchase with StoreKit 2 verification (never trust unverified
    /// transactions — spec §73). Server-side truth arrives via App Store
    /// Server Notifications → subscriptions table.
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(.verified(let transaction)):
            await transaction.finish()
            return true
        case .success(.unverified):
            return false
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }
}
