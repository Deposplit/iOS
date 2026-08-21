import hexagon
import Foundation

@Observable
final class ContactsViewModel {

    var contacts: [Contact] = []

    private let contactManagement: any ContactManagement
    private let shareManagement: any ShareManagement

    init(contactManagement: any ContactManagement, shareManagement: any ShareManagement) {
        self.contactManagement = contactManagement
        self.shareManagement = shareManagement
    }

    func load() {
        contacts = (try? contactManagement.listContacts()) ?? []
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { contacts[$0] }
        toDelete.forEach { try? contactManagement.deleteContact(contactId: $0.id) }
        contacts = (try? contactManagement.listContacts()) ?? []
    }

    /// Item 10 — flags this contact's *current* key as compromised, out-of-band-triggered (the
    /// user has some independent reason to believe it). From this point, any signed rotation
    /// notice claiming continuity from that key is refused auto-accept; only a fresh
    /// human-verified relink can move the contact forward.
    func markKeyCompromised(_ contact: Contact) {
        try? contactManagement.markKeyCompromised(contactId: contact.id, verifyKey: nil)
        load()
    }

    /// Item 12 — this device's own choice to stop (or resume) heartbeating `contact` (who is the
    /// owner of shares this device holds from them). Low-stakes and reversible, unlike marking a
    /// key compromised — no confirmation needed.
    func toggleHeartbeatEmission(_ contact: Contact) {
        try? shareManagement.setHeartbeatEmissionOptedOut(contactId: contact.id, optedOut: !contact.heartbeatEmissionOptedOut)
        load()
    }
}
