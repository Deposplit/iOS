import hexagon
import Foundation

@Observable
final class ContactsViewModel {

    var contacts: [Contact] = []
    /// Contacts who still hold a key this device no longer signs with, so they cannot address it
    /// any more. Only ever non-empty after an identity was re-established without the old key to
    /// sign a rotation notice with — a phone switch, or a catalogue restored onto a fresh install.
    var awaitingRelink: Set<UUID> = []

    private let contactManagement: any ContactManagement
    private let shareManagement: any ShareManagement

    init(contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
    }

    func load() {
        contacts = (try? contactManagement.listContacts()) ?? []
        awaitingRelink = Set(contactManagement.contactsAwaitingRelink().map(\.id))
    }

    /// The manual fallback. Anything arriving from a contact clears them automatically, but a
    /// contact who holds no share and sends nothing never produces evidence, so the list would
    /// otherwise never empty.
    func markRelinked(_ contactId: UUID) {
        contactManagement.markRelinked(contactId)
        load()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { contacts[$0] }
        toDelete.forEach { try? contactManagement.deleteContact(contactId: $0.id) }
        contacts = (try? contactManagement.listContacts()) ?? []
    }

    /// Flags this contact's *current* key as compromised, out-of-band-triggered (the
    /// user has some independent reason to believe it). From this point, any signed rotation
    /// notice claiming continuity from that key is refused auto-accept; only a fresh
    /// human-verified relink can move the contact forward.
    func markKeyCompromised(_ contact: Contact) {
        try? contactManagement.markKeyCompromised(contactId: contact.id, verifyKey: nil)
        load()
    }

    /// This device's own choice to stop (or resume) heartbeating `contact` (who is the
    /// owner of shares this device holds from them). Low-stakes and reversible, unlike marking a
    /// key compromised — no confirmation needed.
    func toggleHeartbeatEmission(_ contact: Contact) {
        try? shareManagement.setHeartbeatEmissionOptedOut(contactId: contact.id, optedOut: !contact.heartbeatEmissionOptedOut)
        load()
    }

    /// A purely local disambiguation label; never touches keys/level/cipherSuite. Pass
    /// nil (or a blank string, normalized service-side) to clear an existing nickname.
    func rename(_ contact: Contact, nickname: String?) {
        try? contactManagement.renameContact(contactId: contact.id, nickname: nickname)
        load()
    }
}
