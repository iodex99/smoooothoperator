import SOSync
import StoreKit
import SwiftUI

/// Pro paywall (spec §§7-8, 74): products and prices come exclusively from
/// the App Store — nothing hard-coded, regional pricing automatic.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var products: [Product] = []
    @State private var purchasing = false
    @State private var loading = true
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    GlowRing(progress: 1, lineWidth: 6)
                        .frame(width: 96, height: 96)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(SOTheme.heat)
                }
                .padding(.top, 18)

                VStack(spacing: 4) {
                    Text("SMOOOOTH PRO")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                    Text("Drive the whole game.")
                        .font(.subheadline)
                        .foregroundStyle(SOTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Benefit(
                        icon: "infinity",
                        text: "Unlimited daily challenges — the free tier allows \(DailyRunAllowance.freeRunsPerDay) runs a day"
                    )
                    Benefit(
                        icon: "point.topleft.down.curvedto.point.bottomright.up",
                        text: "Create custom courses and challenge friends"
                    )
                    Benefit(
                        icon: "square.and.arrow.up",
                        text: "Support an independent app built by one driver"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .soCard(padding: 18)

                if loading {
                    ProgressView()
                        .tint(SOTheme.heatStart)
                        .padding(.vertical, 20)
                } else if products.isEmpty {
                    VStack(spacing: 10) {
                        Text("Subscriptions aren't available right now.")
                            .font(.subheadline)
                            .foregroundStyle(SOTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadProducts() } }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(products, id: \.id) { product in
                        Button {
                            purchase(product)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.displayName)
                                        .font(.system(.headline, design: .rounded).weight(.heavy))
                                        .foregroundStyle(.white)
                                    if let period = product.subscription?.subscriptionPeriod {
                                        Text(periodLabel(period))
                                            .font(.caption)
                                            .foregroundStyle(SOTheme.textSecondary)
                                    }
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(.system(.headline, design: .rounded).weight(.heavy))
                                    .monospacedDigit()
                                    .foregroundStyle(SOTheme.heatEnd)
                            }
                            .padding(16)
                            .background(SOTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .strokeBorder(SOTheme.heatStart.opacity(0.55), lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(purchasing)
                    }
                }

                Button("Restore purchases") { Task { await restore() } }
                    .font(.footnote.weight(.semibold))
                    .tint(SOTheme.heatStart)
                    .padding(.vertical, 10)

                // Required disclosure (App Store 3.1.2). Full opacity: this
                // was the least legible text in the app at 3.63:1, below the
                // 4.5:1 minimum, on the one paragraph Apple requires be
                // readable.
                Text("""
                Payment is charged to your Apple ID at confirmation. \
                Subscriptions renew automatically unless cancelled at least \
                24 hours before the end of the current period. Manage or \
                cancel in your App Store settings.
                """)
                    .font(.caption2)
                    .foregroundStyle(SOTheme.textSecondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    Link("Terms of Use", destination: URL(string: "https://smooooth.app/terms")!)
                    Link("Privacy Policy", destination: URL(string: "https://smooooth.app/privacy")!)
                }
                .font(.caption2.weight(.semibold))
                .tint(SOTheme.heatStart)
            }
            .padding(24)
        }
        .background(SOTheme.ground)
        .task { await loadProducts() }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        }
    }

    private func purchase(_ product: Product) {
        purchasing = true
        Task {
            defer { purchasing = false }
            switch await environment.subscriptions.purchase(product) {
            case .success:
                await environment.refreshEntitlement()
                dismiss()
            case .cancelled:
                break
            case .pending:
                // Ask to Buy: the charge may be approved later, and the
                // transaction observer is what will notice.
                notice = "Waiting for approval. Pro unlocks as soon as it's approved."
            case .unverified:
                notice = "That purchase couldn't be verified. You have not been charged twice — contact support if it persists."
            case .failed(let message):
                notice = message
            }
        }
    }

    private func loadProducts() async {
        loading = true
        defer { loading = false }
        products = (try? await environment.subscriptions.products()) ?? []
    }

    private func restore() async {
        do {
            try await environment.subscriptions.restore()
            await environment.refreshEntitlement()
            notice = environment.isPro
                ? "Your Pro subscription is active."
                : "No previous purchase found on this Apple ID."
        } catch {
            notice = "Couldn't reach the App Store. Try again in a moment."
        }
    }

    private func periodLabel(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .week: "Weekly"
        case .month: "Monthly"
        case .year: "Yearly"
        case .day: "Daily"
        @unknown default: ""
        }
    }
}

private struct Benefit: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SOTheme.heatStart)
                .frame(width: 30, height: 30)
                .background(SOTheme.heatStart.opacity(0.12), in: Circle())
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
    }
}
