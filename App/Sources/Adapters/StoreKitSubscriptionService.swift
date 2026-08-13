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

    /// Outcome of a purchase attempt — the paywall must be able to tell a
    /// cancellation from a failure from an approval still pending, because
    /// they need very different words on screen.
    enum PurchaseOutcome: Sendable {
        case success
        case cancelled
        /// Ask to Buy / SCA: the charge may still be approved later, and the
        /// transaction observer is what will hear about it.
        case pending
        case unverified
        case failed(String)
    }

    private var observer: Task<Void, Never>?

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

    /// Observes StoreKit for the app's lifetime. Without this, renewals,
    /// refunds, Ask-to-Buy approvals, promo-code redemptions and purchases
    /// made on another device are never seen by the app, and unfinished
    /// transactions are redelivered forever.
    func startObserving(onChange: @escaping @Sendable () -> Void) {
        guard observer == nil else { return }
        observer = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                _ = self
                onChange()
            }
        }
    }

    /// Purchase with StoreKit 2 verification (never trust unverified
    /// transactions — spec §73). Server-side truth arrives via App Store
    /// Server Notifications → subscriptions table.
    /// `appAccountToken` is the ONLY link between an Apple transaction and a
    /// Supabase account: Apple echoes it back in the signed transaction that
    /// reaches our webhook. Without it a purchase can never be attributed to
    /// the person who made it.
    func purchase(_ product: Product, appAccountToken: UUID?) async -> PurchaseOutcome {
        do {
            var options: Set<Product.PurchaseOption> = []
            if let appAccountToken {
                options.insert(.appAccountToken(appAccountToken))
            }
            switch try await product.purchase(options: options) {
            case .success(.verified(let transaction)):
                await transaction.finish()
                return .success
            case .success(.unverified):
                // Do NOT finish: leaving it unfinished lets StoreKit redeliver
                // it once the device can verify, instead of silently eating a
                // purchase the user paid for.
                return .unverified
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("This purchase couldn't be completed.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    /// The subscription's stable identity, for claiming a server row that
    /// arrived without attribution (a promo code, or a purchase made before
    /// this device signed in).
    func currentOriginalTransactionId() async -> String? {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if Self.productIds.contains(transaction.productID) {
                return String(transaction.originalID)
            }
        }
        return nil
    }
}
