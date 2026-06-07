import SwiftUI
import StoreKit

/// Subscription paywall. Presented when the user runs out of free drawing time
/// (`free_limit_reached`) or taps an upgrade entry point. Single product
/// ("Kiki Pro", monthly). On a successful purchase/restore it asks the
/// coordinator to resume the stream — the backend cap is now lifted.
struct PaywallView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openURL) private var openURL

    /// Standard Apple EULA. Replace with your own Terms of Use URL if you host one.
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://kiki.app/privacy")!

    private var manager: SubscriptionManager { coordinator.subscriptionManager }

    private var priceText: String {
        if let product = manager.product { return "\(product.displayPrice) / month" }
        return "$3.99 / month"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "sparkles")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Kiki Pro")
                        .font(.largeTitle.bold())
                    Text("You're out of free drawing time this month. Subscribe to keep drawing without limits.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 6) {
                    Text(priceText)
                        .font(.title2.weight(.semibold))
                    Text("Auto-renews monthly. Cancel anytime.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = manager.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    Button {
                        Task {
                            if await manager.purchase() {
                                coordinator.subscriptionDidActivate()
                            }
                        }
                    } label: {
                        Group {
                            if manager.purchaseInFlight {
                                ProgressView().tint(.white)
                            } else {
                                Text("Subscribe").font(.headline)
                            }
                        }
                        .frame(maxWidth: 360)
                        .frame(height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.purchaseInFlight)

                    Button("Restore Purchases") {
                        Task {
                            await manager.restore()
                            if manager.status == .subscribed {
                                coordinator.subscriptionDidActivate()
                            }
                        }
                    }
                    .font(.subheadline)
                    .disabled(manager.purchaseInFlight)
                }

                // App Review 3.1.2 requires this disclosure + functional links.
                VStack(spacing: 4) {
                    Text("Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically unless canceled at least 24 hours before the end of the current period. Manage or cancel in Settings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Terms of Use") { openURL(termsURL) }
                        Button("Privacy Policy") { openURL(privacyURL) }
                    }
                    .font(.caption2)
                }
                .padding(.horizontal, 32)

                Spacer()
            }

            Button {
                coordinator.showPaywall = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .padding(8)
        }
        .task {
            Analytics.track(.paywallShown)
            await manager.loadProduct()
        }
    }
}
