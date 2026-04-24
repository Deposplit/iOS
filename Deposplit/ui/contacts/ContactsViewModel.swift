import Foundation

@Observable
final class ContactsViewModel {

    var contacts: [Contact] = []

    private let repository: ContactRepository

    init(repository: ContactRepository) {
        self.repository = repository
    }

    func load() {
        contacts = repository.getAll()
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { contacts[$0] }
        toDelete.forEach { repository.delete(contactId: $0.id) }
        contacts = repository.getAll()
    }
}
