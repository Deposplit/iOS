import Testing
@testable import hexagon
import Foundation
import CryptoKit

/// A keypair not tied to any Identity instance — used to sign fixture rows "as" a third party
/// (a known contact, or a stranger), independent of the ShareService under test's own identity.
private struct TestKeyPair {
    let publicKey: Data
    private let privateKey: Curve25519.Signing.PrivateKey

    init() {
        privateKey = Curve25519.Signing.PrivateKey()
        publicKey = privateKey.publicKey.rawRepresentation
    }

    func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

private final class InMemoryIdentityStoreForShareServiceTest: IdentityStore {
    private(set) var isRegistered = false
    private var _pseudonym = ""
    private var edPk = Data()
    private var edSk = Data()
    private var xPk = Data()
    private var xSk = Data()

    var pseudonym: String { _pseudonym }
    var edPublicKey: Data { edPk }
    var xPublicKey: Data { xPk }

    func save(pseudonym: String, edPk: Data, edSk: Data, xPk: Data, xSk: Data) throws {
        self._pseudonym = pseudonym
        self.edPk = edPk
        self.edSk = edSk
        self.xPk = xPk
        self.xSk = xSk
        self.isRegistered = true
    }

    func edPrivateKey() throws -> Data { edSk }
    func xPrivateKey() throws -> Data { xSk }
}

/// A genuinely mutable in-memory store (not a no-op) — item 9's rotation-processing tests need to
/// observe the effect of `ContactService.updateContact` on the same contacts `ShareService` reads.
private final class FakeContactRepository: ContactRepository {
    private var contacts: [Contact]
    init(_ contacts: [Contact]) { self.contacts = contacts }
    func getAll() -> [Contact] { contacts }
    func getByEdKey(_ edPublicKey: Data) -> Contact? { contacts.first { $0.edPublicKey == edPublicKey } }
    func getById(_ id: UUID) -> Contact? { contacts.first { $0.id == id } }
    func save(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        contacts.append(contact)
    }
    func delete(contactId: UUID) { contacts.removeAll { $0.id == contactId } }
}

private final class FakeShareRepository: ShareRepository {
    private var shares: [HeldShare] = []
    func getAll() -> [HeldShare] { shares }
    func getPlaintextShare(secretId: UUID) -> Data? { shares.first { $0.secretId == secretId }?.plaintextShare }
    func save(_ share: HeldShare) { shares.append(share) }
    func delete(shareId: UUID) { shares.removeAll { $0.id == shareId } }
}

private final class FakeShareMetadataRepository: ShareMetadataRepository {
    private var metas: [ShareMetadata] = []
    func getAll() throws -> [ShareMetadata] { metas }
    func save(_ share: ShareMetadata) throws { metas.append(share) }
    func delete(shareId: UUID) throws { metas.removeAll { $0.id == shareId } }
}

private final class FakeSecretRepository: SecretRepository {
    private var secrets: [Secret] = []
    func getAll() throws -> [Secret] { secrets }
    func save(_ secret: Secret) throws {
        secrets.removeAll { $0.id == secret.id }
        secrets.append(secret)
    }
    func delete(secretId: UUID) throws { secrets.removeAll { $0.id == secretId } }
}

private struct NoOpShareEncryption: ShareEncryption {
    func encrypt(_ plaintext: Data, recipientXPublicKey: Data) throws -> Data { plaintext }
    func decrypt(_ noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data { noncePlusCiphertext }
}

/// In-memory ShareRelay test double. `listShareRequests` filters by `transactionType`/`state`
/// (role is ignored — every fixture row here is already addressed correctly) since `syncInbox`
/// now issues two differently-filtered queries per relay (deposit/pending, then
/// inventory/approved) that must not see each other's rows.
private final class FakeShareRelay: ShareRelay {
    struct OpenedRequest {
        let secretId: UUID
        let recipientKey: Data
        let transactionType: ShareTransactionType
        let k: Int?
        let n: Int?
    }

    var pending: [ShareRequest] = []
    var byId: [UUID: ShareRequest] = [:]
    var respondCalls: [UUID] = []
    var deletedRequestIds: [UUID] = []
    var openedRequests: [OpenedRequest] = []
    var unreachable = false

    // Item 9
    struct WithdrawCall: Equatable { let senderKey: Data?; let secretId: UUID? }
    var withdrawCalls: [WithdrawCall] = []
    struct PushedRotation: Equatable { let recipientKey: Data; let newEd25519Key: Data; let newX25519Key: Data; let signature: Data }
    var pushedRotations: [PushedRotation] = []
    var rotationsToReturn: [KeyRotation] = []
    var deletedRotationIds: [UUID] = []
    var throwOnWithdraw = false

    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, transactionType: ShareTransactionType, shareId: UUID?, ciphertext: Data?, k: Int?, n: Int?, senderSignature: Data) async throws -> ShareRequest {
        openedRequests.append(OpenedRequest(secretId: secretId, recipientKey: recipientKey, transactionType: transactionType, k: k, n: n))
        let now = Date()
        let selfApproved = transactionType == .inventory
        return ShareRequest(
            id: UUID(), secretId: secretId, senderKey: Data(), recipientKey: recipientKey, label: label,
            secretCreatedAt: secretCreatedAt, transactionType: transactionType, state: selfApproved ? .approved : .pending,
            shareId: shareId, requestedAt: now, respondedAt: selfApproved ? now : nil,
            ciphertext: nil, k: k, n: n, senderSignature: senderSignature, recipientSignature: nil
        )
    }

    struct SimulatedOutage: Error {}

    func listShareRequests(role: Role, transactionType: ShareTransactionType?, state: ShareRequestState?) async throws -> [ShareRequest] {
        if unreachable { throw SimulatedOutage() }
        return pending.filter { (transactionType == nil || $0.transactionType == transactionType) && (state == nil || $0.state == state) }
    }

    func getShareRequest(requestId: UUID) async throws -> ShareRequest {
        byId[requestId]!
    }

    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?, recipientSignature: Data) async throws -> ShareRequest {
        respondCalls.append(requestId)
        let existing = byId[requestId]!
        let updated = ShareRequest(
            id: existing.id, secretId: existing.secretId, senderKey: existing.senderKey, recipientKey: existing.recipientKey,
            label: existing.label, secretCreatedAt: existing.secretCreatedAt, transactionType: existing.transactionType,
            state: approved ? .approved : .denied, shareId: existing.shareId, requestedAt: existing.requestedAt,
            respondedAt: existing.respondedAt, ciphertext: existing.ciphertext, k: existing.k, n: existing.n,
            senderSignature: existing.senderSignature, recipientSignature: existing.recipientSignature
        )
        byId[requestId] = updated
        return updated
    }

    func deleteShareRequest(requestId: UUID) async throws { deletedRequestIds.append(requestId) }
    func deleteShareRequests(senderKey: Data?, secretId: UUID?) async throws {}

    func withdrawShareRequests(senderKey: Data?, secretId: UUID?) async throws {
        withdrawCalls.append(WithdrawCall(senderKey: senderKey, secretId: secretId))
        if throwOnWithdraw { throw SimulatedOutage() }
    }

    func pushRotation(recipientKey: Data, newEd25519Key: Data, newX25519Key: Data, signature: Data) async throws {
        pushedRotations.append(PushedRotation(recipientKey: recipientKey, newEd25519Key: newEd25519Key, newX25519Key: newX25519Key, signature: signature))
    }

    func listRotations() async throws -> [KeyRotation] {
        if unreachable { throw SimulatedOutage() }
        return rotationsToReturn
    }

    func deleteRotation(id: UUID) async throws { deletedRotationIds.append(id) }
}

/// Resolves to the same relay regardless of the requested URL — these tests exercise signature
/// verification, not multi-relay routing (see the fan-out tests below for that).
private final class FixedShareRelayResolver: ShareRelayResolver {
    private let relay: any ShareRelay
    init(_ relay: any ShareRelay) { self.relay = relay }
    func resolve(_ relayBaseUrl: String?) -> any ShareRelay { relay }
}

private let aliceKeys = TestKeyPair()
private let strangerKeys = TestKeyPair()

private let aliceContact = Contact(
    id: UUID(), pseudonym: "alice", edPublicKey: aliceKeys.publicKey,
    xPublicKey: Data(repeating: 0x01, count: 32),
    verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
)

private func makeService(relay: FakeShareRelay, contacts: [Contact] = [aliceContact]) throws -> (svc: ShareService, bob: IdentityService, shareRepo: FakeShareRepository, contactRepo: FakeContactRepository, metaRepo: FakeShareMetadataRepository) {
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let contactRepo = FakeContactRepository(contacts)
    let metaRepo = FakeShareMetadataRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: metaRepo,
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo),
        identity: bobIdentity
    )
    return (svc, bobIdentity, shareRepo, contactRepo, metaRepo)
}

/// Builds a ShareRequest row whose senderSignature is computed by `signer` — separately from
/// `senderKey`, so tests can construct both a genuine row (signer matches senderKey) and a
/// forged one (signer differs from the claimed senderKey).
private func makeSignedRow(
    id: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    transactionType: ShareTransactionType = .deposit, shareId: UUID? = nil, ciphertext: Data? = Data([1, 2, 3]),
    label: String = "test secret", createdAt: Date = Date(),
    k: Int? = nil, n: Int? = nil
) throws -> ShareRequest {
    let secretId = UUID()
    // k/n are required on deposit/inventory rows and forbidden otherwise — default them
    // here (like production's relay-side validation would) so deposit fixtures don't need every
    // call site updated just to keep passing syncInbox's k/n guard.
    let isRoot = transactionType == .deposit || transactionType == .inventory
    let (kk, nn): (Int?, Int?) = isRoot ? (k ?? 2, n ?? 3) : (nil, nil)
    let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: transactionType, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, shareId: shareId, ciphertext: ciphertext, k: kk, n: nn)
    let sig = try signer.sign(canon)
    return ShareRequest(
        id: id, secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, transactionType: transactionType, state: .pending, shareId: shareId,
        requestedAt: Date(), respondedAt: nil, ciphertext: ciphertext, k: kk, n: nn, senderSignature: sig, recipientSignature: nil
    )
}

// Covers the recipient-side signature-verification gating described in deposplit.com/CLAUDE.md's
// BYOR section: syncInbox/listPendingRequests must drop rows with an unverifiable senderSignature
// (unknown sender, or a genuine contact's key but a forged/mismatched signature) instead of
// trusting whatever the relay returns, and respond must reject explicitly.

@Test func syncInboxApprovesAndSavesADepositWithAValidSenderSignatureFromAKnownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: aliceKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls == [id])
    #expect(shareRepo.getAll().map(\.id) == [id])
}

@Test func syncInboxSkipsADepositWhoseSenderSignatureDoesNotVerifyAgainstTheClaimedSender() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _) = try makeService(relay: relay)
    let id = UUID()
    // Signed by a stranger, not by alice — claims to be from alice but doesn't verify against her key.
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func syncInboxSkipsADepositFromAnUnknownSenderEvenWithASelfConsistentSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: strangerKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func listPendingRequestsFiltersOutARowWithAnUnverifiableSenderSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _) = try makeService(relay: relay)
    let row = try makeSignedRow(
        id: UUID(), senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys,
        transactionType: .removal, shareId: UUID(), ciphertext: nil
    )
    relay.pending = [row]

    let result = try await svc.listPendingRequests()

    #expect(result.isEmpty)
}

@Test func respondThrowsSignatureVerificationFailedWhenSenderSignatureDoesNotVerify() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(
        id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys,
        transactionType: .removal, shareId: UUID(), ciphertext: nil
    )
    relay.byId[id] = row

    do {
        try await svc.respond(requestId: id, approved: true)
        Issue.record("expected ShareServiceError.signatureVerificationFailed to be thrown")
    } catch ShareServiceError.signatureVerificationFailed {
        // expected
    }
}

// MARK: - Fan-out across a contact's BYOR relay (deposplit.com/CLAUDE.md's BYOR section)

private final class TwoRelayResolver: ShareRelayResolver {
    private let defaultRelay: any ShareRelay
    private let byorUrl: String
    private let byorRelay: any ShareRelay

    init(default defaultRelay: any ShareRelay, byorUrl: String, byor byorRelay: any ShareRelay) {
        self.defaultRelay = defaultRelay
        self.byorUrl = byorUrl
        self.byorRelay = byorRelay
    }

    func resolve(_ relayBaseUrl: String?) -> any ShareRelay {
        guard let relayBaseUrl else { return defaultRelay }
        return relayBaseUrl == byorUrl ? byorRelay : defaultRelay
    }
}

@Test func syncInboxPollsBothTheDefaultRelayAndAContactsBYORRelayMergingResults() async throws {
    let byorUrl = "http://byor.example:9000"
    let charlieKeys = TestKeyPair()
    let charlieContact = Contact(
        id: UUID(), pseudonym: "charlie", edPublicKey: charlieKeys.publicKey,
        xPublicKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        relayBaseUrl: byorUrl
    )
    let defaultRelay = FakeShareRelay()
    let byorRelay = FakeShareRelay()
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let contactRepo = FakeContactRepository([aliceContact, charlieContact])
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo),
        identity: bobIdentity
    )

    let fromAliceId = UUID()
    let fromAlice = try makeSignedRow(id: fromAliceId, senderKey: aliceKeys.publicKey, recipientKey: bobIdentity.edPublicKey, signer: aliceKeys)
    let fromCharlieId = UUID()
    let fromCharlie = try makeSignedRow(id: fromCharlieId, senderKey: charlieKeys.publicKey, recipientKey: bobIdentity.edPublicKey, signer: charlieKeys)
    defaultRelay.pending = [fromAlice]
    defaultRelay.byId[fromAliceId] = fromAlice
    byorRelay.pending = [fromCharlie]
    byorRelay.byId[fromCharlieId] = fromCharlie

    try await svc.syncInbox()

    #expect(defaultRelay.respondCalls == [fromAliceId])
    #expect(byorRelay.respondCalls == [fromCharlieId])
    #expect(Set(shareRepo.getAll().map(\.id)) == Set([fromAliceId, fromCharlieId]))
}

@Test func syncInboxStillProcessesTheReachableRelayWhenTheOtherIsUnreachable() async throws {
    let byorUrl = "http://byor.example:9000"
    let charlieKeys = TestKeyPair()
    let charlieContact = Contact(
        id: UUID(), pseudonym: "charlie", edPublicKey: charlieKeys.publicKey,
        xPublicKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        relayBaseUrl: byorUrl
    )
    let defaultRelay = FakeShareRelay()
    let byorRelay = FakeShareRelay()
    byorRelay.unreachable = true
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let contactRepo = FakeContactRepository([aliceContact, charlieContact])
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo),
        identity: bobIdentity
    )

    let fromAliceId = UUID()
    let fromAlice = try makeSignedRow(id: fromAliceId, senderKey: aliceKeys.publicKey, recipientKey: bobIdentity.edPublicKey, signer: aliceKeys)
    defaultRelay.pending = [fromAlice]
    defaultRelay.byId[fromAliceId] = fromAlice

    try await svc.syncInbox()

    #expect(defaultRelay.respondCalls == [fromAliceId])
    #expect(shareRepo.getAll().map(\.id) == [fromAliceId])
}

// MARK: - Identity recovery (item 8)

private func makeServiceForRecoveryTest(relay: FakeShareRelay, contacts: [Contact] = [aliceContact]) throws -> (
    svc: ShareService, bob: IdentityService, shareRepo: FakeShareRepository,
    secretRepo: FakeSecretRepository, metaRepo: FakeShareMetadataRepository, contactRepo: FakeContactRepository
) {
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let secretRepo = FakeSecretRepository()
    let metaRepo = FakeShareMetadataRepository()
    let contactRepo = FakeContactRepository(contacts)
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: metaRepo,
        secretRepository: secretRepo,
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo),
        identity: bobIdentity
    )
    return (svc, bobIdentity, shareRepo, secretRepo, metaRepo, contactRepo)
}

/// A self-approved inventory row, as the relay would hand it back — `state: .approved`
/// and `respondedAt` set at creation, since this type has no consent phase (see item 8).
private func makeApprovedRecoveryMetadataRow(
    secretId: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    k: Int = 2, n: Int = 3, label: String = "recovered secret", createdAt: Date = Date()
) throws -> ShareRequest {
    let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: .inventory, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, shareId: nil, ciphertext: nil, k: k, n: n)
    let sig = try signer.sign(canon)
    let now = Date()
    return ShareRequest(
        id: UUID(), secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, transactionType: .inventory, state: .approved, shareId: nil,
        requestedAt: now, respondedAt: now, ciphertext: nil, k: k, n: n, senderSignature: sig, recipientSignature: nil
    )
}

@Test func pushRecoveryMetadataOpensARecoveryMetadataPushForEveryHeldShareFromThatContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    shareRepo.save(HeldShare(
        id: UUID(), secretId: secretId, label: "test secret", contactId: aliceContact.id,
        senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([9]),
        k: 2, n: 3
    ))

    try await svc.pushRecoveryMetadata(contactId: aliceContact.id)

    #expect(relay.openedRequests.count == 1)
    #expect(relay.openedRequests.first?.transactionType == .inventory)
    #expect(relay.openedRequests.first?.secretId == secretId)
    #expect(relay.openedRequests.first?.recipientKey == aliceContact.edPublicKey)
    #expect(relay.openedRequests.first?.k == 2)
    #expect(relay.openedRequests.first?.n == 3)
}

@Test func pushRecoveryMetadataThrowsContactNotFoundForAnUnknownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _, _) = try makeServiceForRecoveryTest(relay: relay)

    do {
        try await svc.pushRecoveryMetadata(contactId: UUID())
        Issue.record("expected ShareServiceError.contactNotFound")
    } catch ShareServiceError.contactNotFound {
        // expected
    }
}

@Test func syncInboxProcessesAnApprovedRecoveryMetadataPushAndRebuildsSecretAndShareMetadata() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    let pushRow = try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: aliceKeys)
    relay.pending = [pushRow]

    try await svc.syncInbox()

    let secrets = try secretRepo.getAll()
    #expect(secrets.map(\.id) == [secretId])
    #expect(secrets.first?.k == 2)
    #expect(secrets.first?.n == 3)
    let metas = try metaRepo.getAll()
    #expect(metas.count == 1)
    #expect(metas.first?.secretId == secretId)
    #expect(metas.first?.contactId == aliceContact.id)
    // Consumed: deleted from the relay so it isn't reprocessed on the next poll.
    #expect(relay.deletedRequestIds == [pushRow.id])
}

@Test func syncInboxIgnoresARecoveryMetadataPushWithAForgedSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    // Claims to be from alice but signed by a stranger.
    let pushRow = try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.pending = [pushRow]

    try await svc.syncInbox()

    #expect(try secretRepo.getAll().isEmpty)
    #expect(try metaRepo.getAll().isEmpty)
    #expect(relay.deletedRequestIds.isEmpty)
}

// MARK: - Item 9: rotation push (client primitive + receive-side) and withdraw tombstone

/// Builds a signed KeyRotation notice — the signing counterpart of `relay.pushRotation`.
/// `signer` is the party whose signature is attached; pass something other than the keypair
/// backing `oldEd25519Key` to build a forged notice.
private func makeSignedRotation(
    oldEd25519Key: Data, recipientKey: Data,
    newEd25519Key: Data = Data(repeating: 0x0a, count: 32),
    newX25519Key: Data = Data(repeating: 0x0b, count: 32),
    signer: TestKeyPair
) throws -> KeyRotation {
    let canon = PayloadCanonical.forRotation(recipientKey: recipientKey, newEd25519Key: newEd25519Key, newX25519Key: newX25519Key)
    let sig = try signer.sign(canon)
    return KeyRotation(id: UUID(), oldEd25519Key: oldEd25519Key, recipientKey: recipientKey, newEd25519Key: newEd25519Key, newX25519Key: newX25519Key, signature: sig, createdAt: Date())
}

@Test func pushRotationSignsWithTheCurrentIdentityAndPushesToTheContactsRelay() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _) = try makeService(relay: relay)
    let newEd = Data(repeating: 0x08, count: 32)
    let newX = Data(repeating: 0x09, count: 32)

    try await svc.pushRotation(contactId: aliceContact.id, newEd25519Key: newEd, newX25519Key: newX)

    #expect(relay.pushedRotations.count == 1)
    let pushed = relay.pushedRotations[0]
    #expect(pushed.recipientKey == aliceContact.edPublicKey)
    #expect(pushed.newEd25519Key == newEd)
    #expect(pushed.newX25519Key == newX)
    let canon = PayloadCanonical.forRotation(recipientKey: aliceContact.edPublicKey, newEd25519Key: newEd, newX25519Key: newX)
    #expect(bob.verify(canon, signature: pushed.signature, publicKey: bob.edPublicKey))
}

@Test func pushRotationThrowsContactNotFoundForAnUnknownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _) = try makeService(relay: relay)

    do {
        try await svc.pushRotation(contactId: UUID(), newEd25519Key: Data(repeating: 0x01, count: 32), newX25519Key: Data(repeating: 0x02, count: 32))
        Issue.record("expected ShareServiceError.contactNotFound")
    } catch ShareServiceError.contactNotFound {
        // expected
    }
}

@Test func syncInboxAutoAcceptsAValidRotationNoticeAndDowngradesVerificationLevelToLow() async throws {
    let relay = FakeShareRelay()
    // aliceContact starts at .veryHigh.
    let (svc, bob, _, contactRepo, _) = try makeService(relay: relay)
    let newEd = Data(repeating: 0x0c, count: 32)
    let newX = Data(repeating: 0x0d, count: 32)
    let notice = try makeSignedRotation(oldEd25519Key: aliceKeys.publicKey, recipientKey: bob.edPublicKey, newEd25519Key: newEd, newX25519Key: newX, signer: aliceKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    let updated = contactRepo.getById(aliceContact.id)
    #expect(updated?.id == aliceContact.id) // updated in place, contactId preserved
    #expect(updated?.edPublicKey == newEd)
    #expect(updated?.xPublicKey == newX)
    #expect(updated?.verificationLevel == .low)
    #expect(relay.deletedRotationIds == [notice.id])
}

@Test func syncInboxNeverRaisesVerificationLevelAboveLowEvenFromAnAlreadyLowerLevel() async throws {
    let relay = FakeShareRelay()
    let daveKeys = TestKeyPair()
    let daveContact = Contact(
        id: UUID(), pseudonym: "dave", edPublicKey: daveKeys.publicKey,
        xPublicKey: Data(repeating: 0x04, count: 32),
        verificationLevel: .veryLow, verifiedAt: nil, addedAt: Date()
    )
    let (svc, bob, _, contactRepo, _) = try makeService(relay: relay, contacts: [daveContact])
    let notice = try makeSignedRotation(oldEd25519Key: daveKeys.publicKey, recipientKey: bob.edPublicKey, signer: daveKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    // Continuity of key control is not a fresh personhood check (item 10) — it can never raise
    // the level, only cap it at .low.
    #expect(contactRepo.getById(daveContact.id)?.verificationLevel == .veryLow)
}

@Test func syncInboxIgnoresARotationNoticeWithAForgedSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, contactRepo, _) = try makeService(relay: relay)
    // Claims to be from alice (oldEd25519Key = aliceKeys.publicKey) but signed by a stranger.
    let notice = try makeSignedRotation(oldEd25519Key: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    #expect(contactRepo.getById(aliceContact.id)?.edPublicKey == aliceContact.edPublicKey)
    #expect(relay.deletedRotationIds.isEmpty)
}

@Test func syncInboxIgnoresARotationNoticeFromAnUnknownOldKey() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, contactRepo, _) = try makeService(relay: relay)
    let notice = try makeSignedRotation(oldEd25519Key: strangerKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    #expect(contactRepo.getAll() == [aliceContact])
    #expect(relay.deletedRotationIds.isEmpty)
}

@Test func deleteHeldShareWithdrawsFromTheSendersRelayScopedBySecretIdThenDeletesLocally() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _) = try makeService(relay: relay)
    let secretId = UUID()
    let shareId = UUID()
    shareRepo.save(HeldShare(id: shareId, secretId: secretId, label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3))

    try await svc.deleteHeldShare(shareId: shareId)

    #expect(relay.withdrawCalls == [FakeShareRelay.WithdrawCall(senderKey: nil, secretId: secretId)])
    #expect(shareRepo.getAll().isEmpty)
}

@Test func deleteAllHeldFromSenderWithdrawsBySenderKeyThenDeletesAllLocally() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _) = try makeService(relay: relay)
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3))
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "y", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([2]), k: 2, n: 3))

    try await svc.deleteAllHeldFromSender(contactId: aliceContact.id)

    #expect(relay.withdrawCalls == [FakeShareRelay.WithdrawCall(senderKey: aliceContact.edPublicKey, secretId: nil)])
    #expect(shareRepo.getAll().isEmpty)
}

@Test func deleteHeldShareStillDeletesLocallyEvenIfTheWithdrawCallFails() async throws {
    let relay = FakeShareRelay()
    relay.throwOnWithdraw = true
    let (svc, _, shareRepo, _, _) = try makeService(relay: relay)
    let shareId = UUID()
    shareRepo.save(HeldShare(id: shareId, secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3))

    try await svc.deleteHeldShare(shareId: shareId)

    #expect(shareRepo.getAll().isEmpty)
}

/// A bare deposit row shaped only for `syncDistributed()`'s purposes — that method never checks
/// signatures, so `senderSignature` is deliberately empty filler, not a genuine signature.
private func makeDepositRow(id: UUID, secretId: UUID, recipientKey: Data, state: ShareRequestState) -> ShareRequest {
    ShareRequest(
        id: id, secretId: secretId, senderKey: Data(repeating: 0x05, count: 32), recipientKey: recipientKey,
        label: "test secret", secretCreatedAt: Date(), transactionType: .deposit, state: state,
        shareId: nil, requestedAt: Date(), respondedAt: state == .pending ? nil : Date(),
        ciphertext: nil, k: 2, n: 3, senderSignature: Data(), recipientSignature: nil
    )
}

@Test func syncDistributedRemovesTheLocalPointerAndDeletesTheRelayRowForAWithdrawnDeposit() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try metaRepo.save(ShareMetadata(id: depositId, secretId: secretId, contactId: aliceContact.id))
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.edPublicKey, state: .withdrawn)]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().isEmpty)
    #expect(relay.deletedRequestIds == [depositId])
}

@Test func syncDistributedStillUpsertsNormallyForANonWithdrawnRow() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.edPublicKey, state: .approved)]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().map(\.id) == [depositId])
    #expect(relay.deletedRequestIds.isEmpty)
}
