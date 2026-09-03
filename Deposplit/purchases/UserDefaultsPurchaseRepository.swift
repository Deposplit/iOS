import hexagon
import Foundation

/// The entitlement as this device last saw it, cached in `UserDefaults` beside the default relay.
///
/// The cache exists so the domain's `isPremium()` can stay synchronous and keep working offline;
/// StoreKit remains the source of truth and refreshes it. A device owner can of course flip it,
/// which is exactly the honour-system posture SECURITY.md already records.
final class UserDefaultsPurchaseRepository: PurchaseRepository, Sendable {

    private let key = "premiumUnlocked"

    func isPremium() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    func setPremium(_ premium: Bool) {
        UserDefaults.standard.set(premium, forKey: key)
    }
}
