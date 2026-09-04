import Testing
@testable import hexagon
import Foundation

private final class InMemoryContactRelinkRepositoryForTests: ContactRelinkRepository {
    private var relinks: [ContactRelink] = []
    func getAll() -> [ContactRelink] { relinks }
    func get(_ contactId: UUID) -> ContactRelink? { relinks.first { $0.contactId == contactId } }
    func save(_ relink: ContactRelink) {
        relinks.removeAll { $0.contactId == relink.contactId }
        relinks.append(relink)
    }
}

/// Only identityCreatedAt is read by ContactService; the rest of the port is never reached.
private final class FakeIdentityStoreForContacts: IdentityStore {
    var identityCreatedAt: Date?
    init(identityCreatedAt: Date? = nil) { self.identityCreatedAt = identityCreatedAt }
    var isRegistered: Bool { identityCreatedAt != nil }
    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {}
    func rotate(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {}
    var pseudonym: String { "" }
    var verifyKey: Data? { nil }
    var encKey: Data? { nil }
    func signKey() throws -> Data { Data() }
    func decKey() throws -> Data { Data() }
    func previousDecKey() -> Data? { nil }
}

private var identityStoreForContacts: any IdentityStore { FakeIdentityStoreForContacts() }

private final class InMemoryContactRepositoryForContactServiceTest: ContactRepository {
    private(set) var contacts: [Contact] = []
    func getAll() -> [Contact] { contacts }
    func getByVerifyKey(_ verifyKey: Data) -> Contact? { contacts.first { $0.verifyKey == verifyKey } }
    func getById(_ id: UUID) -> Contact? { contacts.first { $0.id == id } }
    func save(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
    }
    func delete(contactId: UUID) { contacts.removeAll { $0.id == contactId } }
}

private final class FakePurchaseRepositoryForContactServiceTest: PurchaseRepository {
    var premium: Bool
    init(premium: Bool = false) { self.premium = premium }
    func isPremium() -> Bool { premium }
}

private func makeContact() -> Contact {
    Contact(
        id: UUID(), pseudonym: "bob",
        verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: Date.distantPast, addedAt: Date.distantPast
    )
}

// updateContact — contact-update-in-place, preserving contactId, used both for benign key
// rotation and holder-driven recovery relinking.

@Test func updateContactPreservesContactIdWhileChangingKeysAndLevel() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
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
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
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
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
    let original = makeContact()
    repo.save(original)

    try svc.updateContact(contactId: original.id, verifyKey: nil, encKey: nil, newCipherSuite: nil, verificationLevel: .high)

    let updated = repo.getById(original.id)
    #expect(updated?.verifyKey == original.verifyKey)
    #expect(updated?.verificationLevel == .high)
}

@Test func updateContactThrowsContactNotFoundForAnUnknownId() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    do {
        try svc.updateContact(contactId: UUID(), verifyKey: nil, encKey: nil, newCipherSuite: nil, verificationLevel: .high)
        Issue.record("expected ContactError.contactNotFound")
    } catch ContactError.contactNotFound {
        // expected
    }
}

// Crypto agility — cipher-suite-only changes and suite-driven key-length validation.

@Test func updateContactRequiresAFreshLevelOnACipherSuiteOnlyChangeWithNoKeyValueChange() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
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
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    do {
        try svc.addFromQr(pseudonym: "eve", verifyKey: Data(repeating: 0x01, count: 16), encKey: Data(repeating: 0x02, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: nil)
        Issue.record("expected ContactError.invalidKeySize")
    } catch ContactError.invalidKeySize {
        // expected
    }
}

@Test func addFromQrStoresTheAssertedCipherSuite() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    try svc.addFromQr(pseudonym: "eve", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: nil)

    #expect(repo.getAll().first?.cipherSuite == .current)
}

// Local contact nicknames — renameContact never touches
// verificationLevel/keyChangedAt/verifiedAt/keys, because a rename is not an identity change.

@Test func renameContactSetsANicknameWithoutTouchingKeysLevelOrKeyChangedAt() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
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
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
    let original = makeContact()
    repo.save(original)

    try svc.renameContact(contactId: original.id, nickname: "  Paul  ")
    #expect(repo.getById(original.id)?.nickname == "Paul")

    try svc.renameContact(contactId: original.id, nickname: "   ")
    #expect(repo.getById(original.id)?.nickname == nil)
}

@Test func renameContactCanClearAnExistingNickname() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())
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
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    do {
        try svc.renameContact(contactId: UUID(), nickname: "Paul")
        Issue.record("expected ContactError.contactNotFound")
    } catch ContactError.contactNotFound {
        // expected
    }
}

@Test func addManuallyAndAddFromQrTrimAndNormalizeTheNickname() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: nil, nickname: "  Bobby  ")
    try svc.addFromQr(pseudonym: "carol", verifyKey: Data(repeating: 0x03, count: 32), encKey: Data(repeating: 0x04, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: nil, nickname: "   ")

    let contacts = repo.getAll()
    #expect(contacts.first { $0.pseudonym == "bob" }?.nickname == "Bobby")
    #expect(contacts.first { $0.pseudonym == "carol" }?.nickname == nil)
}

@Test func addManuallyDefaultsTheNicknameToNilWhenOmitted() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: nil, nickname: nil)

    #expect(repo.getAll().first?.nickname == nil)
}

// MARK: - free tier

@Test func addManuallyRefusesARelayOverrideWithoutPremium() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    // ContactError is not Equatable, so match the case rather than the value.
    do {
        try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: "https://relay.example", nickname: nil)
        Issue.record("expected a hand-typed relay override to require Premium")
    } catch ContactError.premiumRequired {
    }

    #expect(repo.getAll().isEmpty)
}

@Test func addManuallyAcceptsARelayOverrideWithPremium() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(premium: true), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    try svc.addManually(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), verificationLevel: .low, relayBaseUrl: "https://relay.example", nickname: nil)

    #expect(repo.getAll().first?.relayBaseUrl == "https://relay.example")
}

/// The free half of BYOR. A relay named in a scanned QR code is the contact saying where their own
/// mailbox is, so refusing it would mean a free device cannot share with a self-hoster at all — a
/// different product, not a paywall.
@Test func addFromQrAcceptsARelayOverrideWithoutPremium() throws {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepositoryForContactServiceTest(), identityStore: identityStoreForContacts, relinkRepository: InMemoryContactRelinkRepositoryForTests())

    try svc.addFromQr(pseudonym: "bob", verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32), cipherSuite: .current, verificationLevel: .veryHigh, relayBaseUrl: "https://relay.example", nickname: nil)

    #expect(repo.getAll().first?.relayBaseUrl == "https://relay.example")
}


// ---------------------------------------------------------------------------
// contactsAwaitingRelink() — who still holds a key this device no longer signs with
// ---------------------------------------------------------------------------

private let identityBorn = Date(timeIntervalSince1970: 1_780_000_000)

private func awaitingSetup(
    _ identityCreatedAt: Date?
) -> (ContactService, InMemoryContactRepositoryForContactServiceTest, InMemoryContactRelinkRepositoryForTests) {
    let repo = InMemoryContactRepositoryForContactServiceTest()
    let relinks = InMemoryContactRelinkRepositoryForTests()
    let svc = ContactService(
        contactRepository: repo,
        purchases: FakePurchaseRepositoryForContactServiceTest(),
        identityStore: FakeIdentityStoreForContacts(identityCreatedAt: identityCreatedAt),
        relinkRepository: relinks
    )
    return (svc, repo, relinks)
}

private func contactAdded(_ at: Date) -> Contact {
    Contact(
        id: UUID(), pseudonym: "bob",
        verifyKey: Data(repeating: 0x01, count: 32), encKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: at, addedAt: at
    )
}

@Test func aContactAddedBeforeTheCurrentIdentityIsAwaitingRelink() {
    let (svc, repo, _) = awaitingSetup(identityBorn)
    let older = contactAdded(identityBorn.addingTimeInterval(-60))
    repo.save(older)
    #expect(svc.contactsAwaitingRelink().map(\.id) == [older.id])
}

@Test func aContactAddedAfterTheCurrentIdentityIsNot() {
    let (svc, repo, _) = awaitingSetup(identityBorn)
    repo.save(contactAdded(identityBorn.addingTimeInterval(60)))
    #expect(svc.contactsAwaitingRelink().isEmpty)
}

// Anything arriving from a contact is proof, since the relay only returns rows addressed to the
// caller's current key.
@Test func aRelinkRecordedSinceTheCurrentIdentityClearsTheContact() {
    let (svc, repo, _) = awaitingSetup(identityBorn)
    let older = contactAdded(identityBorn.addingTimeInterval(-60))
    repo.save(older)
    svc.markRelinked(older.id)
    #expect(svc.contactsAwaitingRelink().isEmpty)
}

// A relink from before this identity existed was to the key that is gone, so it proves nothing.
@Test func aRelinkOlderThanTheCurrentIdentityDoesNotClearTheContact() {
    let (svc, repo, relinks) = awaitingSetup(identityBorn)
    let older = contactAdded(identityBorn.addingTimeInterval(-120))
    repo.save(older)
    relinks.save(ContactRelink(contactId: older.id, observedAt: identityBorn.addingTimeInterval(-60)))
    #expect(svc.contactsAwaitingRelink().map(\.id) == [older.id])
}

// No recorded start is no basis to judge — flagging every contact on a guess would be a false alarm
// on a device that never lost anything.
@Test func anUnrecordedIdentityStartPutsNobodyOnTheList() {
    let (svc, repo, _) = awaitingSetup(nil)
    repo.save(contactAdded(Date.distantPast))
    #expect(svc.contactsAwaitingRelink().isEmpty)
}

@Test func markRelinkedIsIdempotent() {
    let (svc, repo, relinks) = awaitingSetup(identityBorn)
    let older = contactAdded(identityBorn.addingTimeInterval(-60))
    repo.save(older)
    svc.markRelinked(older.id)
    svc.markRelinked(older.id)
    #expect(relinks.getAll().count == 1)
}
