import hexagon
import Foundation
import StoreKit

/// The single non-consumable that unlocks Premium. Effectively permanent once anyone has bought
/// it: it is the identifier the App Store record is keyed by.
enum PremiumProduct {
    static let id = "com.deposplit.premium"
}

/// The App Store side of the freemium unlock — products, purchase, restore — and the thing that
/// keeps `UserDefaultsPurchaseRepository` up to date.
///
/// The split is deliberate. StoreKit is asynchronous and needs the network; the domain's
/// `isPremium()` is neither. So this refreshes the cached answer and the domain reads the cache,
/// which means a device offline, or launched before this ever runs, still knows what it owns.
///
/// Development needs no App Store Connect record: `Deposplit.storekit` is attached to the shared
/// scheme, so the unlock can actually be bought in the Simulator, and Debug → StoreKit → Manage
/// Transactions deletes the purchase again to test the locked state.
@Observable
final class StoreKitPurchaseStore: PurchaseRepository {

    /// The entitlement for the UI to observe, so a purchase updates every gated screen at once.
    /// `isPremium()` below is the same answer for the domain, read straight from the cache and
    /// deliberately not actor-isolated.
    private(set) var isUnlocked: Bool
    private(set) var product: Product?
    private(set) var isPurchasing = false
    var errorMessage: String?

    nonisolated private let cache: UserDefaultsPurchaseRepository
    /// Purchases completed outside the app — another device, Ask to Buy, an interrupted purchase
    /// that resolves later. Without this listener such a transaction would never be finished.
    private var updates: Task<Void, Never>?

    init(cache: UserDefaultsPurchaseRepository) {
        self.cache = cache
        self.isUnlocked = cache.isPremium()
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
    }

    nonisolated func isPremium() -> Bool { cache.isPremium() }

    func load() async {
        product = try? await Product.products(for: [PremiumProduct.id]).first
        await refresh()
    }

    /// The entitlement as the App Store currently reports it, written through to the cache.
    /// `revocationDate` matters: a refunded purchase stays in the entitlement list.
    func refresh() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == PremiumProduct.id, transaction.revocationDate == nil {
                entitled = true
            }
        }
        cache.setPremium(entitled)
        isUnlocked = entitled
    }

    func purchase() async {
        guard let product else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result {
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refresh()
            }
            // .userCancelled needs no message, and .pending resolves through `Transaction.updates`.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Non-consumables normally reappear on their own through `currentEntitlements`, so this is the
    /// affordance App Review expects rather than the mechanism most restores actually take.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}
