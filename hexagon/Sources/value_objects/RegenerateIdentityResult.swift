import Foundation

/// Outcome of `ShareManagement.regenerateIdentity()` — how many of this device's contacts were
/// successfully notified of the new key via a signed rotation push before the new identity was
/// activated locally. A contact not reached here never learns of the new key automatically; there
/// is no retry mechanism, matching item 9's existing one-shot `pushRotation` semantics.
public struct RegenerateIdentityResult: Equatable {
    public let notifiedContacts: Int
    public let totalContacts: Int

    public init(notifiedContacts: Int, totalContacts: Int) {
        self.notifiedContacts = notifiedContacts
        self.totalContacts = totalContacts
    }
}
