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

private final class FakeContactRepository: ContactRepository {
    private let contacts: [Contact]
    init(_ contacts: [Contact]) { self.contacts = contacts }
    func getAll() -> [Contact] { contacts }
    func getByEdKey(_ edPublicKey: Data) -> Contact? { contacts.first { $0.edPublicKey == edPublicKey } }
    func getById(_ id: UUID) -> Contact? { contacts.first { $0.id == id } }
    func save(_ contact: Contact) {}
    func delete(contactId: UUID) {}
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

/// In-memory ShareRelay test double. `listShareRequests` filters by `requestType`/`state` (role
/// is ignored — every fixture row here is already addressed correctly) since `syncInbox` now
/// issues two differently-filtered queries per relay (pickUp/pending, then
/// recoveryMetadata/approved) that must not see each other's rows.
private final class FakeShareRelay: ShareRelay {
    struct OpenedRequest {
        let secretId: UUID
        let recipientKey: Data
        let requestType: ShareRequestType
        let k: Int?
        let n: Int?
    }

    var pending: [ShareRequest] = []
    var byId: [UUID: ShareRequest] = [:]
    var respondCalls: [UUID] = []
    var deletedRequestIds: [UUID] = []
    var openedRequests: [OpenedRequest] = []
    var unreachable = false

    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, requestType: ShareRequestType, shareId: UUID?, ciphertext: Data?, k: Int?, n: Int?, senderSignature: Data) async throws -> ShareRequest {
        openedRequests.append(OpenedRequest(secretId: secretId, recipientKey: recipientKey, requestType: requestType, k: k, n: n))
        let now = Date()
        let selfApproved = requestType == .recoveryMetadata
        return ShareRequest(
            id: UUID(), secretId: secretId, senderKey: Data(), recipientKey: recipientKey, label: label,
            secretCreatedAt: secretCreatedAt, requestType: requestType, state: selfApproved ? .approved : .pending,
            shareId: shareId, requestedAt: now, respondedAt: selfApproved ? now : nil,
            ciphertext: nil, k: k, n: n, senderSignature: senderSignature, recipientSignature: nil
        )
    }

    struct SimulatedOutage: Error {}

    func listShareRequests(role: Role, requestType: ShareRequestType?, state: ShareRequestState?) async throws -> [ShareRequest] {
        if unreachable { throw SimulatedOutage() }
        return pending.filter { (requestType == nil || $0.requestType == requestType) && (state == nil || $0.state == state) }
    }

    func getShareRequest(requestId: UUID) async throws -> ShareRequest {
        byId[requestId]!
    }

    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?, recipientSignature: Data) async throws -> ShareRequest {
        respondCalls.append(requestId)
        let existing = byId[requestId]!
        let updated = ShareRequest(
            id: existing.id, secretId: existing.secretId, senderKey: existing.senderKey, recipientKey: existing.recipientKey,
            label: existing.label, secretCreatedAt: existing.secretCreatedAt, requestType: existing.requestType,
            state: approved ? .approved : .denied, shareId: existing.shareId, requestedAt: existing.requestedAt,
            respondedAt: existing.respondedAt, ciphertext: existing.ciphertext, k: existing.k, n: existing.n,
            senderSignature: existing.senderSignature, recipientSignature: existing.recipientSignature
        )
        byId[requestId] = updated
        return updated
    }

    func deleteShareRequest(requestId: UUID) async throws { deletedRequestIds.append(requestId) }
    func deleteShareRequests(senderKey: Data?, secretId: UUID?) async throws {}
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

private func makeService(relay: FakeShareRelay) throws -> (svc: ShareService, bob: IdentityService, shareRepo: FakeShareRepository) {
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: FakeContactRepository([aliceContact]),
        identity: bobIdentity
    )
    return (svc, bobIdentity, shareRepo)
}

/// Builds a ShareRequest row whose senderSignature is computed by `signer` — separately from
/// `senderKey`, so tests can construct both a genuine row (signer matches senderKey) and a
/// forged one (signer differs from the claimed senderKey).
private func makeSignedRow(
    id: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    requestType: ShareRequestType = .pickUp, shareId: UUID? = nil, ciphertext: Data? = Data([1, 2, 3]),
    label: String = "test secret", createdAt: Date = Date(),
    k: Int? = nil, n: Int? = nil
) throws -> ShareRequest {
    let secretId = UUID()
    // k/n are required on pickUp/recoveryMetadata rows and forbidden otherwise — default them
    // here (like production's relay-side validation would) so pickUp fixtures don't need every
    // call site updated just to keep passing syncInbox's k/n guard.
    let isRoot = requestType == .pickUp || requestType == .recoveryMetadata
    let (kk, nn): (Int?, Int?) = isRoot ? (k ?? 2, n ?? 3) : (nil, nil)
    let canon = PayloadCanonical.forOpen(secretId: secretId, requestType: requestType, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, shareId: shareId, ciphertext: ciphertext, k: kk, n: nn)
    let sig = try signer.sign(canon)
    return ShareRequest(
        id: id, secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, requestType: requestType, state: .pending, shareId: shareId,
        requestedAt: Date(), respondedAt: nil, ciphertext: ciphertext, k: kk, n: nn, senderSignature: sig, recipientSignature: nil
    )
}

// Covers the recipient-side signature-verification gating described in deposplit.com/CLAUDE.md's
// BYOR section: syncInbox/listPendingRequests must drop rows with an unverifiable senderSignature
// (unknown sender, or a genuine contact's key but a forged/mismatched signature) instead of
// trusting whatever the relay returns, and respond must reject explicitly.

@Test func syncInboxApprovesAndSavesAPickUpWithAValidSenderSignatureFromAKnownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: aliceKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls == [id])
    #expect(shareRepo.getAll().map(\.id) == [id])
}

@Test func syncInboxSkipsAPickUpWhoseSenderSignatureDoesNotVerifyAgainstTheClaimedSender() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo) = try makeService(relay: relay)
    let id = UUID()
    // Signed by a stranger, not by alice — claims to be from alice but doesn't verify against her key.
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func syncInboxSkipsAPickUpFromAnUnknownSenderEvenWithASelfConsistentSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo) = try makeService(relay: relay)
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
    let (svc, bob, _) = try makeService(relay: relay)
    let row = try makeSignedRow(
        id: UUID(), senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys,
        requestType: .delete, shareId: UUID(), ciphertext: nil
    )
    relay.pending = [row]

    let result = try await svc.listPendingRequests()

    #expect(result.isEmpty)
}

@Test func respondThrowsSignatureVerificationFailedWhenSenderSignatureDoesNotVerify() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(
        id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys,
        requestType: .delete, shareId: UUID(), ciphertext: nil
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
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: FakeContactRepository([aliceContact, charlieContact]),
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
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: FakeContactRepository([aliceContact, charlieContact]),
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

private func makeServiceForRecoveryTest(relay: FakeShareRelay) throws -> (
    svc: ShareService, bob: IdentityService, shareRepo: FakeShareRepository,
    secretRepo: FakeSecretRepository, metaRepo: FakeShareMetadataRepository
) {
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let secretRepo = FakeSecretRepository()
    let metaRepo = FakeShareMetadataRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: metaRepo,
        secretRepository: secretRepo,
        contactRepository: FakeContactRepository([aliceContact]),
        identity: bobIdentity
    )
    return (svc, bobIdentity, shareRepo, secretRepo, metaRepo)
}

/// A self-approved recoveryMetadata row, as the relay would hand it back — `state: .approved`
/// and `respondedAt` set at creation, since this type has no consent phase (see item 8).
private func makeApprovedRecoveryMetadataRow(
    secretId: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    k: Int = 2, n: Int = 3, label: String = "recovered secret", createdAt: Date = Date()
) throws -> ShareRequest {
    let canon = PayloadCanonical.forOpen(secretId: secretId, requestType: .recoveryMetadata, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, shareId: nil, ciphertext: nil, k: k, n: n)
    let sig = try signer.sign(canon)
    let now = Date()
    return ShareRequest(
        id: UUID(), secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, requestType: .recoveryMetadata, state: .approved, shareId: nil,
        requestedAt: now, respondedAt: now, ciphertext: nil, k: k, n: n, senderSignature: sig, recipientSignature: nil
    )
}

@Test func pushRecoveryMetadataOpensARecoveryMetadataPushForEveryHeldShareFromThatContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    shareRepo.save(HeldShare(
        id: UUID(), secretId: secretId, label: "test secret", contactId: aliceContact.id,
        senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([9]),
        k: 2, n: 3
    ))

    try await svc.pushRecoveryMetadata(contactId: aliceContact.id)

    #expect(relay.openedRequests.count == 1)
    #expect(relay.openedRequests.first?.requestType == .recoveryMetadata)
    #expect(relay.openedRequests.first?.secretId == secretId)
    #expect(relay.openedRequests.first?.recipientKey == aliceContact.edPublicKey)
    #expect(relay.openedRequests.first?.k == 2)
    #expect(relay.openedRequests.first?.n == 3)
}

@Test func pushRecoveryMetadataThrowsContactNotFoundForAnUnknownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _) = try makeServiceForRecoveryTest(relay: relay)

    do {
        try await svc.pushRecoveryMetadata(contactId: UUID())
        Issue.record("expected ShareServiceError.contactNotFound")
    } catch ShareServiceError.contactNotFound {
        // expected
    }
}

@Test func syncInboxProcessesAnApprovedRecoveryMetadataPushAndRebuildsSecretAndShareMetadata() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, secretRepo, metaRepo) = try makeServiceForRecoveryTest(relay: relay)
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
    let (svc, bob, _, secretRepo, metaRepo) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    // Claims to be from alice but signed by a stranger.
    let pushRow = try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.edPublicKey, signer: strangerKeys)
    relay.pending = [pushRow]

    try await svc.syncInbox()

    #expect(try secretRepo.getAll().isEmpty)
    #expect(try metaRepo.getAll().isEmpty)
    #expect(relay.deletedRequestIds.isEmpty)
}
