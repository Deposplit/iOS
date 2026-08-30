import Foundation

/// A signed rotation notice that arrived claiming continuity from a key the local contact record
/// already flags as compromised. Persisted locally the moment it's detected — the
/// relay is a best-effort mailbox that may garbage-collect the underlying notice at any time, so
/// this durable local record, not the relay, is what the conflict UI reads from. Never
/// auto-resolved: the only paths forward are a human `dismiss` (this was a false alarm, or the
/// user has otherwise handled it) or a fresh human-verified relink via `ContactManagement
/// .updateContact` — never an automatic acceptance of the offered new keys.
public struct KeyConflict: Identifiable, Equatable {
    public let id: UUID
    public let contactId: UUID
    public let oldVerifyKey: Data
    public let newVerifyKey: Data
    public let newEncKey: Data
    public let detectedAt: Date

    public init(id: UUID, contactId: UUID, oldVerifyKey: Data, newVerifyKey: Data, newEncKey: Data, detectedAt: Date) {
        self.id = id
        self.contactId = contactId
        self.oldVerifyKey = oldVerifyKey
        self.newVerifyKey = newVerifyKey
        self.newEncKey = newEncKey
        self.detectedAt = detectedAt
    }
}
