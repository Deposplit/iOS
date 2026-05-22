import hexagon
import Foundation

@Observable
final class ContactsViewModel {

    var contacts: [Contact] = []

    private let contactManagement: any ContactManagement

    init(contactManagement: any ContactManagement) {
        self.contactManagement = contactManagement
    }

    func load() {
        contacts = (try? contactManagement.listContacts()) ?? []
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { contacts[$0] }
        toDelete.forEach { try? contactManagement.deleteContact(contactId: $0.id) }
        contacts = (try? contactManagement.listContacts()) ?? []
    }
}
