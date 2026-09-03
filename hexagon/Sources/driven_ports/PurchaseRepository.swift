import Foundation

/// Whether this device has the one-time Deposplit Premium unlock.
///
/// Deliberately synchronous and deliberately local. The relay never learns payment status, so there
/// is nothing to ask it; and a device that cannot reach the App Store must still be able to split a
/// secret, so the answer is a cached one the adapter refreshes rather than a live query. The domain
/// only ever reads it.
///
/// Enforcement is client-side and therefore honour-system by design — see SECURITY.md. What this
/// port buys is not unforgeability but a single place where the free/paid boundary is stated.
public protocol PurchaseRepository {
    func isPremium() -> Bool
}
