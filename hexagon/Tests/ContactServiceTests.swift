import Testing
@testable import hexagon
import Foundation

private final class InMemoryContactRepositoryForContactServiceTest: ContactRepository {
    private(set) var contacts: [Contact] = []
    func getAll() -> [Contact] { contacts }
    func getByEdKey(_ edPublicKey: Data) -> Contact? { contacts.first { $0.edPublicKey == edPublicKey } }
    func getById(_ id: UUID) -> Contact? { contacts.first { $0.id == id } }
    func save(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
    }
    func delete(contactId: UUID) { contacts.removeAll { $0.id == contactId } }
}

private func makeContact() -> Contact {
    Contact(
        id: UUID(), pseudonym: "bob",
        edPublicKey: Data(repeating: 0x01, count: 32), xPublicKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: Date.distantPast, addedAt: Date.distantPast
    )
}

// updateContact (item 8) — contact-update-in-place, preserving contactId, used both for
// benign key rotation and holder-driven recovery relinking. See deposplit.com/CLAUDE.md item 8.

@Test func updateContactPreservesContactIdWhileChangingKeysAndLevel() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)
    let newEd = Data(repeating: 0x03, count: 32)
    let newX = Data(repeating: 0x04, count: 32)

    try svc.updateContact(contactId: original.id, edPublicKey: newEd, xPublicKey: newX, verificationLevel: .low)

    let updated = repo.getById(original.id)
    #expect(updated?.id == original.id)
    #expect(updated?.pseudonym == original.pseudonym)
    #expect(updated?.edPublicKey == newEd)
    #expect(updated?.xPublicKey == newX)
    #expect(updated?.verificationLevel == .low)
}

@Test func updateContactThrowsWhenChangingKeysWithoutSupplyingALevel() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    do {
        try svc.updateContact(contactId: original.id, edPublicKey: Data(repeating: 0x03, count: 32), xPublicKey: nil, verificationLevel: nil)
        Issue.record("expected ContactError.levelRequiredOnKeyChange")
    } catch ContactError.levelRequiredOnKeyChange {
        // expected
    }
}

@Test func updateContactCanChangeOnlyTheLevelWithoutTouchingKeys() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    try svc.updateContact(contactId: original.id, edPublicKey: nil, xPublicKey: nil, verificationLevel: .high)

    let updated = repo.getById(original.id)
    #expect(updated?.edPublicKey == original.edPublicKey)
    #expect(updated?.verificationLevel == .high)
}

@Test func updateContactThrowsContactNotFoundForAnUnknownId() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    do {
        try svc.updateContact(contactId: UUID(), edPublicKey: nil, xPublicKey: nil, verificationLevel: .high)
        Issue.record("expected ContactError.contactNotFound")
    } catch ContactError.contactNotFound {
        // expected
    }
}
