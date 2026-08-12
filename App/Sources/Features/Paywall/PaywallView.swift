import StoreKit
import SwiftUI

/// Pro paywall (spec §§7-8, 74): products and prices come exclusively from
/// the App Store — nothing hard-coded, regional pricing automatic.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var products: [Product] = []
    @State private var purchasing = false

    var body: some View {
        VStack(spacing: 20) {
            Text("SMOOOOTH PRO")
                .font(.system(.title, design: .rounded).weight(.heavy))
                .tracking(1.5)

            VStack(alignment: .leading, spacing: 10) {
                Benefit(text: "Unlimited challenges & ghost racing")
                Benefit(text: "Create custom courses and challenge friends")
                Benefit(text: "Advanced driving analytics")
            }

            if products.isEmpty {
                ProgressView()
            } else {
                ForEach(products, id: \.id) { product in
                    Button {
                        purchase(product)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(product.displayName).font(.headline)
                                if let period = product.subscription?.subscriptionPeriod {
                                    Text(periodLabel(period))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(product.displayPrice).font(.headline)
                        }
                        .padding(14)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(purchasing)
                }
            }

            Button("Restore purchases") {
                Task { try? await environment.subscriptions.restore() }
            }
            .font(.footnote)

            Text("Subscriptions renew automatically until cancelled in your App Store settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .task {
            products = (try? await environment.subscriptions.products()) ?? []
        }
    }

    private func purchase(_ product: Product) {
        purchasing = true
        Task {
            defer { purchasing = false }
            if (try? await environment.subscriptions.purchase(product)) == true {
                dismiss()
            }
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
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.primary)
    }
}
