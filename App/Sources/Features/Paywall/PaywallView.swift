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
                    Benefit(icon: "flag.checkered.2.crossed", text: "Unlimited challenges & ghost racing")
                    Benefit(icon: "point.topleft.down.curvedto.point.bottomright.up", text: "Create custom courses and challenge friends")
                    Benefit(icon: "chart.xyaxis.line", text: "Advanced driving analytics")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .soCard(padding: 18)

                if products.isEmpty {
                    ProgressView()
                        .tint(SOTheme.heatStart)
                        .padding(.vertical, 20)
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

                Button("Restore purchases") {
                    Task { try? await environment.subscriptions.restore() }
                }
                .font(.footnote.weight(.semibold))
                .tint(SOTheme.heatStart)

                Text("Subscriptions renew automatically until cancelled in your App Store settings.")
                    .font(.caption2)
                    .foregroundStyle(SOTheme.textSecondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .background(SOTheme.ground)
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
