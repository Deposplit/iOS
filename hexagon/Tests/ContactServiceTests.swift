import Testing
@testable import hexagon
import Foundation

private final class InMemoryContactRepositoryForContactServiceTest: ContactRepository {
    private(set) var contacts: [Contact] = []
    func getAll() -> [Contact] { contacts }
    func getByEdKey(_ verifyKey: Data) -> Contact? { contacts.first { $0.verifyKey == verifyKey } }
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
        verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32),
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

    try svc.updateContact(contactId: original.id, verifyKey: newEd, encKey: newX, newCipherSuite: nil, verificationLevel: .low)

    let updated = repo.getById(original.id)
    #expect(updated?.id == original.id)
    #expect(updated?.pseudonym == original.pseudonym)
    #expect(updated?.verifyKey == newEd)
    #expect(updated?.encKey == newX)
    #expect(updated?.verificationLevel == .low)
}

@Test func updateContactThrowsWhenChangingKeysWithoutSupplyingALevel() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    do {
        try svc.updateContact(contactId: original.id, verifyKey: Data(repeating: 0x03, count: 32), encKey: nil, newCipherSuite: nil, verificationLevel: nil)
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

    try svc.updateContact(contactId: original.id, verifyKey: nil, encKey: nil, newCipherSuite: nil, verificationLevel: .high)

    let updated = repo.getById(original.id)
    #expect(updated?.verifyKey == original.verifyKey)
    #expect(updated?.verificationLevel == .high)
}

@Test func updateContactThrowsContactNotFoundForAnUnknownId() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    do {
        try svc.updateContact(contactId: UUID(), verifyKey: nil, encKey: nil, newCipherSuite: nil, verificationLevel: .high)
        Issue.record("expected ContactError.contactNotFound")
    } catch ContactError.contactNotFound {
        // expected
    }
}

// Item 14 ("crypto agility") — cipher-suite-only changes and suite-driven key-length validation.

@Test func updateContactRequiresAFreshLevelOnACipherSuiteOnlyChangeWithNoKeyValueChange() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    do {
        try svc.updateContact(contactId: original.id, verifyKey: nil, encKey: nil, newCipherSuite: .current, verificationLevel: nil)
        Issue.record("expected ContactError.levelRequiredOnKeyChange")
    } catch ContactError.levelRequiredOnKeyChange {
        // expected
    }

    try svc.updateContact(contactId: original.id, verifyKey: nil, encKey: nil, newCipherSuite: .current, verificationLevel: .low)
    let updated = repo.getById(original.id)
    #expect(updated?.cipherSuite == .current)
    #expect(updated?.verificationLevel == .low)
    #expect(updated?.keyChangedAt != nil)
}

@Test func addFromQrRejectsAVerifyKeyWhoseLengthDoesNotMatchTheAssertedCipherSuite() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    do {
        try svc.addFromQr(pseudonym: "eve", verifyKey: Data(repeating: 0x01, count: 16), encKey: Data(repeating: 0x02, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: nil)
        Issue.record("expected ContactError.invalidKeySize")
    } catch ContactError.invalidKeySize {
        // expected
    }
}

@Test func addFromQrStoresTheAssertedCipherSuite() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    try svc.addFromQr(pseudonym: "eve", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: nil)

    #expect(repo.getAll().first?.cipherSuite == .current)
}

// Item 15 ("local contact nicknames") — renameContact never touches
// verificationLevel/keyChangedAt/verifiedAt/keys, matching CLAUDE.md's requirement that a
// rename is not an identity change.

@Test func renameContactSetsANicknameWithoutTouchingKeysLevelOrKeyChangedAt() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    try svc.renameContact(contactId: original.id, nickname: "Coworker Paul")

    let updated = repo.getById(original.id)
    #expect(updated?.nickname == "Coworker Paul")
    #expect(updated?.pseudonym == original.pseudonym)
    #expect(updated?.verifyKey == original.verifyKey)
    #expect(updated?.encKey == original.encKey)
    #expect(updated?.verificationLevel == original.verificationLevel)
    #expect(updated?.verifiedAt == original.verifiedAt)
    #expect(updated?.keyChangedAt == nil)
}

@Test func renameContactTrimsAndCollapsesABlankNicknameToNil() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    let original = makeContact()
    repo.save(original)

    try svc.renameContact(contactId: original.id, nickname: "  Paul  ")
    #expect(repo.getById(original.id)?.nickname == "Paul")

    try svc.renameContact(contactId: original.id, nickname: "   ")
    #expect(repo.getById(original.id)?.nickname == nil)
}

@Test func renameContactCanClearAnExistingNickname() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)
    var original = makeContact()
    original = Contact(
        id: original.id, pseudonym: original.pseudonym, verifyKey: original.verifyKey, encKey: original.encKey,
        verificationLevel: original.verificationLevel, verifiedAt: original.verifiedAt, addedAt: original.addedAt,
        nickname: "Paul"
    )
    repo.save(original)

    try svc.renameContact(contactId: original.id, nickname: nil)

    #expect(repo.getById(original.id)?.nickname == nil)
}

@Test func renameContactThrowsForAnUnknownContactId() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    do {
        try svc.renameContact(contactId: UUID(), nickname: "Paul")
        Issue.record("expected ContactError.contactNotFound")
    } catch ContactError.contactNotFound {
        // expected
    }
}

@Test func addManuallyAndAddFromQrTrimAndNormalizeTheNickname() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: nil, nickname: "  Bobby  ")
    try svc.addFromQr(pseudonym: "carol", verifyKey: Data(repeating: 0x03, count: 32), encKey: Data(repeating: 0x04, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: "   ")

    let contacts = repo.getAll()
    #expect(contacts.first { $0.pseudonym == "bob" }?.nickname == "Bobby")
    #expect(contacts.first { $0.pseudonym == "carol" }?.nickname == nil)
}

@Test func addManuallyDefaultsTheNicknameToNilWhenOmitted() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo)

    try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: nil, nickname: nil)

    #expect(repo.getAll().first?.nickname == nil)
}
