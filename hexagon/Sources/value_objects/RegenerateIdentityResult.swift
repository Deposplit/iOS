import Foundation

/// Outcome of `ShareManagement.regenerateIdentity()` — how many of this device's contacts were
/// successfully notified of the new key via a signed rotation push before the new identity was
/// activated locally. A contact not reached here never learns of the new key automatically; there
/// is no retry mechanism, matching `pushRotation`'s own one-shot semantics.
public struct RegenerateIdentityResult: Equatable {
    public let notifiedContacts: Int
    public let totalContacts: Int
    /// Whether the pre-rotation drain — collecting anything still addressed to the old identity —
    /// completed. Rotation proceeds either way, deliberately: an unreachable relay must not be able
    /// to block a user who is rotating precisely because they think their key is compromised.
    ///
    /// Reported rather than silently dropped so the UI can say what was skipped. It is a warning,
    /// not a loss: the displaced `decKey` is retained one generation, so a deposit that was not
    /// drained still opens on a later poll.
    public let drainSucceeded: Bool

    public init(notifiedContacts: Int, totalContacts: Int, drainSucceeded: Bool) {
        self.notifiedContacts = notifiedContacts
        self.totalContacts = totalContacts
        self.drainSucceeded = drainSucceeded
    }
}
