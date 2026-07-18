import Foundation
import Observation
import StoreKit
import Sentry

/// StoreKit 2 subscription state for the single "Kiki Pro" auto-renewable
/// subscription. Owns the on-device source of truth (`Transaction`) and pushes
/// each verified transaction's signed JWS to the backend (`verify`), which is
/// what actually lifts the fal free-tier cap (`users.subscription_status`).
///
/// On-device entitlement is authoritative for what the *user* sees; the backend
/// sync is best-effort + retried (launch re-post + App Store Server
/// Notifications webhook reconcile if a single post fails).
@MainActor
@Observable
final class SubscriptionManager {
    static let productID = "com.don.Kiki.pro.monthly"

    enum Status: Equatable {
        case unknown        // not yet checked
        case subscribed
        case notSubscribed
    }

    private(set) var status: Status = .unknown
    private(set) var product: Product?
    private(set) var purchaseInFlight = false
    /// Human-readable last error for the paywall to surface (purchase/restore).
    var lastError: String?

    /// Posts a verified transaction's signed JWS to the backend. Injected so the
    /// manager stays decoupled from the networking layer.
    private let verify: @Sendable (String) async throws -> Void

    private var updatesTask: Task<Void, Never>?

    init(verify: @escaping @Sendable (String) async throws -> Void) {
        self.verify = verify
        // Long-lived listener for transactions that arrive outside an explicit
        // purchase: renewals, Ask-to-Buy approvals, refunds/revocations, and
        // purchases made on another device. Apple recommends starting this at
        // launch and keeping it for the app's lifetime.
        // Lives for the app's lifetime (the manager is an app-lifetime singleton
        // owned by AppCoordinator), so there's no deinit cancellation — Apple
        // recommends keeping this listener running for the whole app lifetime.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.apply(result)
            }
        }
    }

    /// Load the product definition (price/title) for the paywall.
    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            if product == nil {
                Log.warn("subscription.product_missing", attributes: [
                    "event": "subscription.product_missing",
                    "product_id": Self.productID,
                ])
            }
        } catch {
            SentrySDK.capture(error: error) { $0.setTag(value: "subscription.loadProduct", key: "op") }
        }
    }

    /// Re-sync from the device's current entitlements. Call on launch and after
    /// Restore Purchases. Posts each current entitlement to the backend so a
    /// missed webhook (or a fresh install) reconciles.
    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, tx.productID == Self.productID else { continue }
            let entitled = tx.revocationDate == nil
                && (tx.expirationDate ?? .distantPast) > .now
            if entitled { active = true }
            await syncToBackend(result.jwsRepresentation)
        }
        status = active ? .subscribed : .notSubscribed
    }

    /// Initiate a purchase. Returns true if the user is now subscribed.
    func purchase() async -> Bool {
        lastError = nil
        if product == nil { await loadProduct() }
        guard let product else {
            lastError = "Subscription is unavailable right now. Please try again."
            return false
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let tx) = verification else {
                    lastError = "Purchase could not be verified."
                    return false
                }
                await syncToBackend(verification.jwsRepresentation)
                await tx.finish()
                status = .subscribed
                Analytics.track(.subscriptionPurchased, properties: ["product_id": Self.productID])
                return true
            case .userCancelled:
                return false
            case .pending:
                lastError = "Your purchase is pending approval."
                return false
            @unknown default:
                lastError = "Purchase did not complete."
                return false
            }
        } catch {
            lastError = error.localizedDescription
            SentrySDK.capture(error: error) { $0.setTag(value: "subscription.purchase", key: "op") }
            return false
        }
    }

    /// Restore Purchases. StoreKit 2 reads entitlements from the device, but
    /// `AppStore.sync()` forces a refresh against the App Store if needed.
    func restore() async {
        lastError = nil
        do {
            try await AppStore.sync()
        } catch {
            // sync() throwing is usually a cancelled auth prompt — not fatal;
            // currentEntitlements may still resolve.
            SentrySDK.capture(error: error) {
                $0.setTag(value: "subscription.restore", key: "op")
                $0.setLevel(.warning)
            }
        }
        await refreshEntitlements()
        if status == .subscribed {
            Analytics.track(.subscriptionRestored, properties: ["product_id": Self.productID])
        } else {
            lastError = "No active subscription to restore."
        }
    }

    // MARK: - Private

    private func apply(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let tx) = result, tx.productID == Self.productID else { return }
        await syncToBackend(result.jwsRepresentation)
        let entitled = tx.revocationDate == nil && (tx.expirationDate ?? .distantPast) > .now
        status = entitled ? .subscribed : .notSubscribed
        await tx.finish()
    }

    /// Best-effort backend post. A failure here doesn't change on-device status
    /// (Apple is the source of truth for the user); the launch re-post + webhook
    /// reconcile the backend column that gates the fal cap.
    private func syncToBackend(_ jws: String) async {
        do {
            try await verify(jws)
        } catch {
            SentrySDK.capture(error: error) {
                $0.setTag(value: "subscription.verifyBackend", key: "op")
                $0.setLevel(.warning)
            }
        }
    }
}
