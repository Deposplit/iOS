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
    private var _verifyKey = Data()
    private var _signKey = Data()
    private var _encKey = Data()
    private var _decKey = Data()
    private var _previousDecKey: Data?

    var pseudonym: String { _pseudonym }
    var verifyKey: Data? { _verifyKey }
    var encKey: Data? { _encKey }

    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        self._pseudonym = pseudonym
        self._verifyKey = verifyKey
        self._signKey = signKey
        self._encKey = encKey
        self._decKey = decKey
        self._previousDecKey = nil
        self.isRegistered = true
    }

    func rotate(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        self._previousDecKey = _decKey
        self._verifyKey = verifyKey
        self._signKey = signKey
        self._encKey = encKey
        self._decKey = decKey
    }

    func signKey() throws -> Data { _signKey }
    func decKey() throws -> Data { _decKey }
    func previousDecKey() -> Data? { _previousDecKey }
}

/// A genuinely mutable in-memory store (not a no-op) — the rotation-processing tests need to
/// observe the effect of `ContactService.updateContact` on the same contacts `ShareService` reads.
private final class FakeContactRepository: ContactRepository {
    private var contacts: [Contact]
    init(_ contacts: [Contact]) { self.contacts = contacts }
    func getAll() -> [Contact] { contacts }
    func getByVerifyKey(_ verifyKey: Data) -> Contact? { contacts.first { $0.verifyKey == verifyKey } }
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
    func save(_ share: ShareMetadata) throws {
        metas.removeAll { $0.id == share.id }
        metas.append(share)
    }
    func delete(shareId: UUID) throws { metas.removeAll { $0.id == shareId } }
}

/// Toggleable, like `FakeShareRelay.unreachable` — a test flips it to buy the unlock mid-run.
private final class FakePurchaseRepository: PurchaseRepository {
    var premium: Bool
    init(premium: Bool = false) { self.premium = premium }
    func isPremium() -> Bool { premium }
}

private final class FakeKeyConflictRepository: KeyConflictRepository {
    private var conflicts: [KeyConflict] = []
    func getAll() throws -> [KeyConflict] { conflicts }
    func save(_ conflict: KeyConflict) throws { conflicts.append(conflict) }
    func delete(id: UUID) throws { conflicts.removeAll { $0.id == id } }
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

private final class FakeRetainedDepositRepository: RetainedDepositRepository {
    private var blobs: [RetainedDepositBlob] = []
    func getAll() throws -> [RetainedDepositBlob] { blobs }
    func save(_ blob: RetainedDepositBlob) throws {
        blobs.removeAll { $0.id == blob.id }
        blobs.append(blob)
    }
    func delete(id: UUID) throws { blobs.removeAll { $0.id == id } }
}

private struct NoOpShareEncryption: ShareEncryption {
    func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data { plaintext }
    func decrypt(_ noncePlusCiphertext: Data, recipientEncKey: Data) throws -> Data { noncePlusCiphertext }
}

/// Stands in for the real failure at pickup: a share sealed to a key this device no longer holds.
private struct FailingShareEncryption: ShareEncryption {
    struct SimulatedFailure: Error {}
    func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data { plaintext }
    func decrypt(_ noncePlusCiphertext: Data, recipientEncKey: Data) throws -> Data { throw SimulatedFailure() }
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
        let mimeType: MimeType?
    }

    var pending: [ShareRequest] = []
    var byId: [UUID: ShareRequest] = [:]
    var respondCalls: [UUID] = []
    var deletedRequestIds: [UUID] = []
    var openedRequests: [OpenedRequest] = []
    var unreachable = false

    // Rotation push and withdraw tombstone
    struct WithdrawCall: Equatable { let senderKey: Data?; let secretId: UUID? }
    var withdrawCalls: [WithdrawCall] = []
    struct PushedRotation: Equatable { let recipientKey: Data; let newVerifyKey: Data; let newEncKey: Data; let newCipherSuite: CipherSuite; let signature: Data }
    var pushedRotations: [PushedRotation] = []
    var rotationsToReturn: [KeyRotation] = []
    var deletedRotationIds: [UUID] = []
    var throwOnWithdraw = false
    var throwOnPushRotation = false

    func openShareRequest(secretId: UUID, recipientKey: Data, label: String, secretCreatedAt: Date, transactionType: ShareTransactionType, ciphertext: Data?, k: Int?, n: Int?, mimeType: MimeType?, senderSignature: Data) async throws -> ShareRequest {
        openedRequests.append(OpenedRequest(secretId: secretId, recipientKey: recipientKey, transactionType: transactionType, k: k, n: n, mimeType: mimeType))
        let now = Date()
        let selfApproved = transactionType == .inventory
        return ShareRequest(
            id: UUID(), secretId: secretId, senderKey: Data(), recipientKey: recipientKey, label: label,
            secretCreatedAt: secretCreatedAt, transactionType: transactionType, state: selfApproved ? .approved : .pending,
            requestedAt: now, respondedAt: selfApproved ? now : nil,
            ciphertext: nil, k: k, n: n, mimeType: mimeType, senderSignature: senderSignature, recipientSignature: nil
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
            state: approved ? .approved : .denied, requestedAt: existing.requestedAt,
            respondedAt: existing.respondedAt, ciphertext: existing.ciphertext, k: existing.k, n: existing.n,
            senderSignature: existing.senderSignature, recipientSignature: recipientSignature
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

    func pushRotation(recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite, signature: Data) async throws {
        if throwOnPushRotation { throw SimulatedOutage() }
        pushedRotations.append(PushedRotation(recipientKey: recipientKey, newVerifyKey: newVerifyKey, newEncKey: newEncKey, newCipherSuite: newCipherSuite, signature: signature))
    }

    func listRotations() async throws -> [KeyRotation] {
        if unreachable { throw SimulatedOutage() }
        return rotationsToReturn
    }

    func deleteRotation(id: UUID) async throws { deletedRotationIds.append(id) }

    // Custodial heartbeat
    struct PushedHeartbeat: Equatable { let ownerKey: Data; let secretIds: [UUID]; let optedOut: Bool; let signature: Data }
    var pushedHeartbeats: [PushedHeartbeat] = []
    var heartbeatsToReturn: [CustodyHeartbeat] = []
    var throwOnPushHeartbeat = false

    func pushHeartbeat(ownerKey: Data, secretIds: [UUID], optedOut: Bool, signature: Data) async throws {
        if throwOnPushHeartbeat { throw SimulatedOutage() }
        pushedHeartbeats.append(PushedHeartbeat(ownerKey: ownerKey, secretIds: secretIds, optedOut: optedOut, signature: signature))
    }

    func listHeartbeats() async throws -> [CustodyHeartbeat] {
        if unreachable { throw SimulatedOutage() }
        return heartbeatsToReturn
    }
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
    id: UUID(), pseudonym: "alice", verifyKey: aliceKeys.publicKey,
    encKey: Data(repeating: 0x01, count: 32),
    verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
)

private func makeService(
    relay: FakeShareRelay,
    contacts: [Contact] = [aliceContact],
    encryption: any ShareEncryption = NoOpShareEncryption(),
    // Passed in rather than returned, so the existing tuple destructurings keep their arity.
    purchases: FakePurchaseRepository = FakePurchaseRepository()
) throws -> (
    svc: ShareService, bob: IdentityService, shareRepo: FakeShareRepository, contactRepo: FakeContactRepository,
    metaRepo: FakeShareMetadataRepository, conflictRepo: FakeKeyConflictRepository, retainedRepo: FakeRetainedDepositRepository
) {
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let contactRepo = FakeContactRepository(contacts)
    let metaRepo = FakeShareMetadataRepository()
    let conflictRepo = FakeKeyConflictRepository()
    let retainedRepo = FakeRetainedDepositRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: encryption,
        shareRepository: shareRepo,
        shareMetadataRepository: metaRepo,
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: conflictRepo,
        retainedDepositRepository: retainedRepo,
        identity: bobIdentity,
        purchases: purchases
    )
    return (svc, bobIdentity, shareRepo, contactRepo, metaRepo, conflictRepo, retainedRepo)
}

/// Builds a ShareRequest row whose senderSignature is computed by `signer` — separately from
/// `senderKey`, so tests can construct both a genuine row (signer matches senderKey) and a
/// forged one (signer differs from the claimed senderKey).
private func makeSignedRow(
    id: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    transactionType: ShareTransactionType = .deposit, ciphertext: Data? = Data([1, 2, 3]),
    label: String = "test secret", createdAt: Date = Date(),
    k: Int? = nil, n: Int? = nil, mimeType: MimeType? = nil
) throws -> ShareRequest {
    let secretId = UUID()
    // k/n/mimeType are required on deposit/inventory rows and forbidden otherwise — default them
    // here (like production's relay-side validation would) so deposit fixtures don't need every
    // call site updated just to keep passing syncInbox's guard.
    let isRoot = transactionType == .deposit || transactionType == .inventory
    let (kk, nn): (Int?, Int?) = isRoot ? (k ?? 2, n ?? 3) : (nil, nil)
    let mt: MimeType? = isRoot ? (mimeType ?? .default) : nil
    let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: transactionType, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, ciphertext: ciphertext, k: kk, n: nn, mimeType: mt)
    let sig = try signer.sign(canon)
    return ShareRequest(
        id: id, secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, transactionType: transactionType, state: .pending,
        requestedAt: Date(), respondedAt: nil, ciphertext: ciphertext, k: kk, n: nn, mimeType: mt, senderSignature: sig, recipientSignature: nil
    )
}

// Covers the recipient-side signature-verification gating BYOR requires — a third-party relay
// performs no verification of its own, so syncInbox/listPendingRequests must drop rows with an
// unverifiable senderSignature (unknown sender, or a genuine contact's key but a forged or
// mismatched signature) instead of trusting whatever the relay returns, and respond must reject
// explicitly.

@Test func syncInboxApprovesAndSavesADepositWithAValidSenderSignatureFromAKnownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls == [id])
    #expect(shareRepo.getAll().map(\.id) == [id])
}

@Test func syncInboxLeavesADepositPendingWhenTheShareCannotBeDecrypted() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay, encryption: FailingShareEncryption())
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    // Approving is what clears the relay's only copy of the ciphertext, so a pickup that couldn't
    // be stored locally must leave the row pending for the next poll to retry — approving first
    // would consume the share and lose it silently.
    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
    #expect(relay.byId[id]?.state == .pending)
}

@Test func syncInboxSkipsADepositWhoseSenderSignatureDoesNotVerifyAgainstTheClaimedSender() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    // Signed by a stranger, not by alice — claims to be from alice but doesn't verify against her key.
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func syncInboxSkipsADepositFromAnUnknownSenderEvenWithASelfConsistentSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: strangerKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys)
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func listPendingRequestsFiltersOutARowWithAnUnverifiableSenderSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _, _, _) = try makeService(relay: relay)
    let row = try makeSignedRow(
        id: UUID(), senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys,
        transactionType: .removal, ciphertext: nil
    )
    relay.pending = [row]

    let result = try await svc.listPendingRequests()

    #expect(result.isEmpty)
}

@Test func respondThrowsSignatureVerificationFailedWhenSenderSignatureDoesNotVerify() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(
        id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys,
        transactionType: .removal, ciphertext: nil
    )
    relay.byId[id] = row

    do {
        try await svc.respond(requestId: id, approved: true)
        Issue.record("expected ShareServiceError.signatureVerificationFailed to be thrown")
    } catch ShareServiceError.signatureVerificationFailed {
        // expected
    }
}

// MARK: - Fan-out across a contact's BYOR relay

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
        id: UUID(), pseudonym: "charlie", verifyKey: charlieKeys.publicKey,
        encKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        relayBaseUrl: byorUrl
    )
    let defaultRelay = FakeShareRelay()
    let byorRelay = FakeShareRelay()
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let shareRepo = FakeShareRepository()
    let contactRepo = FakeContactRepository([aliceContact, charlieContact])
    let purchases = FakePurchaseRepository()
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: FakeKeyConflictRepository(),
        retainedDepositRepository: FakeRetainedDepositRepository(),
        identity: bobIdentity,
        purchases: purchases
    )

    let fromAliceId = UUID()
    let fromAlice = try makeSignedRow(id: fromAliceId, senderKey: aliceKeys.publicKey, recipientKey: bobIdentity.verifyKey, signer: aliceKeys)
    let fromCharlieId = UUID()
    let fromCharlie = try makeSignedRow(id: fromCharlieId, senderKey: charlieKeys.publicKey, recipientKey: bobIdentity.verifyKey, signer: charlieKeys)
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
        id: UUID(), pseudonym: "charlie", verifyKey: charlieKeys.publicKey,
        encKey: Data(repeating: 0x02, count: 32),
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
    let purchases = FakePurchaseRepository()
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: FakeKeyConflictRepository(),
        retainedDepositRepository: FakeRetainedDepositRepository(),
        identity: bobIdentity,
        purchases: purchases
    )

    let fromAliceId = UUID()
    let fromAlice = try makeSignedRow(id: fromAliceId, senderKey: aliceKeys.publicKey, recipientKey: bobIdentity.verifyKey, signer: aliceKeys)
    defaultRelay.pending = [fromAlice]
    defaultRelay.byId[fromAliceId] = fromAlice

    try await svc.syncInbox()

    #expect(defaultRelay.respondCalls == [fromAliceId])
    #expect(shareRepo.getAll().map(\.id) == [fromAliceId])
}

// MARK: - Identity recovery

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
    let purchases = FakePurchaseRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: NoOpShareEncryption(),
        shareRepository: shareRepo,
        shareMetadataRepository: metaRepo,
        secretRepository: secretRepo,
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: FakeKeyConflictRepository(),
        retainedDepositRepository: FakeRetainedDepositRepository(),
        identity: bobIdentity,
        purchases: purchases
    )
    return (svc, bobIdentity, shareRepo, secretRepo, metaRepo, contactRepo)
}

/// A self-approved inventory row, as the relay would hand it back — `state: .approved`
/// and `respondedAt` set at creation, since this type has no consent phase.
private func makeApprovedRecoveryMetadataRow(
    secretId: UUID, senderKey: Data, recipientKey: Data, signer: TestKeyPair,
    k: Int = 2, n: Int = 3, mimeType: MimeType = .default,
    label: String = "recovered secret", createdAt: Date = Date()
) throws -> ShareRequest {
    let canon = PayloadCanonical.forOpen(secretId: secretId, transactionType: .inventory, recipientKey: recipientKey, label: label, secretCreatedAt: createdAt, ciphertext: nil, k: k, n: n, mimeType: mimeType)
    let sig = try signer.sign(canon)
    let now = Date()
    return ShareRequest(
        id: UUID(), secretId: secretId, senderKey: senderKey, recipientKey: recipientKey, label: label,
        secretCreatedAt: createdAt, transactionType: .inventory, state: .approved,
        requestedAt: now, respondedAt: now, ciphertext: nil, k: k, n: n, mimeType: mimeType, senderSignature: sig, recipientSignature: nil
    )
}

@Test func pushRecoveryMetadataOpensARecoveryMetadataPushForEveryHeldShareFromThatContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    shareRepo.save(HeldShare(
        id: UUID(), secretId: secretId, label: "test secret", contactId: aliceContact.id,
        senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([9]),
        k: 2, n: 3, mimeType: .default
    ))

    try await svc.pushRecoveryMetadata(contactId: aliceContact.id)

    #expect(relay.openedRequests.count == 1)
    #expect(relay.openedRequests.first?.transactionType == .inventory)
    #expect(relay.openedRequests.first?.secretId == secretId)
    #expect(relay.openedRequests.first?.recipientKey == aliceContact.verifyKey)
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
    let pushRow = try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
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
    let pushRow = try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys)
    relay.pending = [pushRow]

    try await svc.syncInbox()

    #expect(try secretRepo.getAll().isEmpty)
    #expect(try metaRepo.getAll().isEmpty)
    #expect(relay.deletedRequestIds.isEmpty)
}

// MARK: - Rotation push (client primitive + receive-side) and withdraw tombstone

/// Builds a signed KeyRotation notice — the signing counterpart of `relay.pushRotation`.
/// `signer` is the party whose signature is attached; pass something other than the keypair
/// backing `oldVerifyKey` to build a forged notice.
private func makeSignedRotation(
    oldVerifyKey: Data, recipientKey: Data,
    newVerifyKey: Data = Data(repeating: 0x0a, count: 32),
    newEncKey: Data = Data(repeating: 0x0b, count: 32),
    newCipherSuite: CipherSuite = .current,
    signer: TestKeyPair
) throws -> KeyRotation {
    let canon = PayloadCanonical.forRotation(recipientKey: recipientKey, newVerifyKey: newVerifyKey, newEncKey: newEncKey, newCipherSuite: newCipherSuite)
    let sig = try signer.sign(canon)
    return KeyRotation(id: UUID(), oldVerifyKey: oldVerifyKey, recipientKey: recipientKey, newVerifyKey: newVerifyKey, newEncKey: newEncKey, newCipherSuite: newCipherSuite, signature: sig, createdAt: Date())
}

@Test func pushRotationSignsWithTheCurrentIdentityAndPushesToTheContactsRelay() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _, _, _) = try makeService(relay: relay)
    let newEd = Data(repeating: 0x08, count: 32)
    let newX = Data(repeating: 0x09, count: 32)

    try await svc.pushRotation(contactId: aliceContact.id, newVerifyKey: newEd, newEncKey: newX, newCipherSuite: .current)

    #expect(relay.pushedRotations.count == 1)
    let pushed = relay.pushedRotations[0]
    #expect(pushed.recipientKey == aliceContact.verifyKey)
    #expect(pushed.newVerifyKey == newEd)
    #expect(pushed.newEncKey == newX)
    #expect(pushed.newCipherSuite == .current)
    let canon = PayloadCanonical.forRotation(recipientKey: aliceContact.verifyKey, newVerifyKey: newEd, newEncKey: newX, newCipherSuite: .current)
    #expect(bob.verify(canon, signature: pushed.signature, publicKey: bob.verifyKey!))
}

@Test func pushRotationThrowsContactNotFoundForAnUnknownContact() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay)

    do {
        try await svc.pushRotation(contactId: UUID(), newVerifyKey: Data(repeating: 0x01, count: 32), newEncKey: Data(repeating: 0x02, count: 32), newCipherSuite: .current)
        Issue.record("expected ShareServiceError.contactNotFound")
    } catch ShareServiceError.contactNotFound {
        // expected
    }
}

@Test func syncInboxAutoAcceptsAValidRotationNoticeAndDowngradesVerificationLevelToLow() async throws {
    let relay = FakeShareRelay()
    // aliceContact starts at .veryHigh.
    let (svc, bob, _, contactRepo, _, _, _) = try makeService(relay: relay)
    let newEd = Data(repeating: 0x0c, count: 32)
    let newX = Data(repeating: 0x0d, count: 32)
    let notice = try makeSignedRotation(oldVerifyKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, newVerifyKey: newEd, newEncKey: newX, signer: aliceKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    let updated = contactRepo.getById(aliceContact.id)
    #expect(updated?.id == aliceContact.id) // updated in place, contactId preserved
    #expect(updated?.verifyKey == newEd)
    #expect(updated?.encKey == newX)
    #expect(updated?.cipherSuite == .current) // threaded through from the notice
    #expect(updated?.verificationLevel == .low)
    #expect(relay.deletedRotationIds == [notice.id])
}

@Test func syncInboxNeverRaisesVerificationLevelAboveLowEvenFromAnAlreadyLowerLevel() async throws {
    let relay = FakeShareRelay()
    let daveKeys = TestKeyPair()
    let daveContact = Contact(
        id: UUID(), pseudonym: "dave", verifyKey: daveKeys.publicKey,
        encKey: Data(repeating: 0x04, count: 32),
        verificationLevel: .veryLow, verifiedAt: nil, addedAt: Date()
    )
    let (svc, bob, _, contactRepo, _, _, _) = try makeService(relay: relay, contacts: [daveContact])
    let notice = try makeSignedRotation(oldVerifyKey: daveKeys.publicKey, recipientKey: bob.verifyKey!, signer: daveKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    // Continuity of key control is not a fresh personhood check — it can never raise
    // the level, only cap it at .low.
    #expect(contactRepo.getById(daveContact.id)?.verificationLevel == .veryLow)
}

@Test func syncInboxIgnoresARotationNoticeWithAForgedSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, contactRepo, _, _, _) = try makeService(relay: relay)
    // Claims to be from alice (oldVerifyKey = aliceKeys.publicKey) but signed by a stranger.
    let notice = try makeSignedRotation(oldVerifyKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    #expect(contactRepo.getById(aliceContact.id)?.verifyKey == aliceContact.verifyKey)
    #expect(relay.deletedRotationIds.isEmpty)
}

@Test func syncInboxIgnoresARotationNoticeFromAnUnknownOldKey() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, contactRepo, _, _, _) = try makeService(relay: relay)
    let notice = try makeSignedRotation(oldVerifyKey: strangerKeys.publicKey, recipientKey: bob.verifyKey!, signer: strangerKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    #expect(contactRepo.getAll() == [aliceContact])
    #expect(relay.deletedRotationIds.isEmpty)
}

@Test func deleteHeldShareWithdrawsFromTheSendersRelayScopedBySecretIdThenDeletesLocally() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let secretId = UUID()
    let shareId = UUID()
    shareRepo.save(HeldShare(id: shareId, secretId: secretId, label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.deleteHeldShare(shareId: shareId)

    #expect(relay.withdrawCalls == [FakeShareRelay.WithdrawCall(senderKey: nil, secretId: secretId)])
    #expect(shareRepo.getAll().isEmpty)
}

@Test func deleteAllHeldFromSenderWithdrawsBySenderKeyThenDeletesAllLocally() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _, _, _) = try makeService(relay: relay)
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "y", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([2]), k: 2, n: 3, mimeType: .default))

    try await svc.deleteAllHeldFromSender(contactId: aliceContact.id)

    #expect(relay.withdrawCalls == [FakeShareRelay.WithdrawCall(senderKey: aliceContact.verifyKey, secretId: nil)])
    #expect(shareRepo.getAll().isEmpty)
}

@Test func deleteHeldShareStillDeletesLocallyEvenIfTheWithdrawCallFails() async throws {
    let relay = FakeShareRelay()
    relay.throwOnWithdraw = true
    let (svc, _, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let shareId = UUID()
    shareRepo.save(HeldShare(id: shareId, secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.deleteHeldShare(shareId: shareId)

    #expect(shareRepo.getAll().isEmpty)
}

/// A bare deposit row shaped only for `syncDistributed()`'s purposes — that method never checks
/// signatures, so `senderSignature` is deliberately empty filler, not a genuine signature.
private func makeDepositRow(id: UUID, secretId: UUID, recipientKey: Data, state: ShareRequestState) -> ShareRequest {
    ShareRequest(
        id: id, secretId: secretId, senderKey: Data(repeating: 0x05, count: 32), recipientKey: recipientKey,
        label: "test secret", secretCreatedAt: Date(), transactionType: .deposit, state: state,
        requestedAt: Date(), respondedAt: state == .pending ? nil : Date(),
        ciphertext: nil, k: 2, n: 3, senderSignature: Data(), recipientSignature: nil
    )
}

@Test func syncDistributedRemovesTheLocalPointerAndDeletesTheRelayRowForAWithdrawnDeposit() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo, _, _) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try metaRepo.save(ShareMetadata(id: depositId, secretId: secretId, contactId: aliceContact.id))
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.verifyKey, state: .withdrawn)]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().isEmpty)
    #expect(relay.deletedRequestIds == [depositId])
}

@Test func syncDistributedStillUpsertsNormallyForANonWithdrawnRow() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo, _, _) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.verifyKey, state: .approved)]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().map(\.id) == [depositId])
    #expect(relay.deletedRequestIds.isEmpty)
}

// MARK: - Stolen-key revocation (compromised-key flag + key conflicts)

@Test func syncInboxRefusesAutoAcceptAndCapturesAKeyConflictWhenTheOldKeyIsRevoked() async throws {
    let relay = FakeShareRelay()
    let revokedAliceContact = Contact(
        id: aliceContact.id, pseudonym: aliceContact.pseudonym, verifyKey: aliceContact.verifyKey,
        encKey: aliceContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        revokedVerifyKeys: [aliceKeys.publicKey]
    )
    let (svc, bob, _, contactRepo, _, conflictRepo, _) = try makeService(relay: relay, contacts: [revokedAliceContact])
    let newEd = Data(repeating: 0x0e, count: 32)
    let newX = Data(repeating: 0x0f, count: 32)
    let notice = try makeSignedRotation(oldVerifyKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, newVerifyKey: newEd, newEncKey: newX, signer: aliceKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    // Not auto-accepted: the contact record is untouched.
    let stillCurrent = contactRepo.getById(revokedAliceContact.id)
    #expect(stillCurrent?.verifyKey == revokedAliceContact.verifyKey)
    #expect(stillCurrent?.verificationLevel == .veryHigh)
    // Captured locally instead — durable, not dependent on the relay still having the notice.
    let conflicts = try conflictRepo.getAll()
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.contactId == revokedAliceContact.id)
    #expect(conflicts.first?.newVerifyKey == newEd)
    #expect(conflicts.first?.newEncKey == newX)
    // The relay notice is consumed either way — the local KeyConflict record is now the durable copy.
    #expect(relay.deletedRotationIds == [notice.id])
}

@Test func syncInboxStillAutoAcceptsANonRevokedRotation() async throws {
    let relay = FakeShareRelay()
    let contactWithUnrelatedRevocation = Contact(
        id: aliceContact.id, pseudonym: aliceContact.pseudonym, verifyKey: aliceContact.verifyKey,
        encKey: aliceContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        revokedVerifyKeys: [Data(repeating: 0x99, count: 32)] // some unrelated historical key, not this one
    )
    let (svc, bob, _, contactRepo, _, conflictRepo, _) = try makeService(relay: relay, contacts: [contactWithUnrelatedRevocation])
    let newEd = Data(repeating: 0x10, count: 32)
    let notice = try makeSignedRotation(oldVerifyKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, newVerifyKey: newEd, signer: aliceKeys)
    relay.rotationsToReturn = [notice]

    try await svc.syncInbox()

    #expect(contactRepo.getById(aliceContact.id)?.verifyKey == newEd)
    #expect(try conflictRepo.getAll().isEmpty)
}

@Test func listAndDismissKeyConflictRoundTrip() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _, conflictRepo, _) = try makeService(relay: relay)
    let conflict = KeyConflict(id: UUID(), contactId: aliceContact.id, oldVerifyKey: aliceKeys.publicKey, newVerifyKey: Data(repeating: 0x01, count: 32), newEncKey: Data(repeating: 0x02, count: 32), detectedAt: Date())
    try conflictRepo.save(conflict)

    #expect(try svc.listKeyConflicts() == [conflict])

    try svc.dismissKeyConflict(id: conflict.id)

    #expect(try svc.listKeyConflicts().isEmpty)
}

@Test func markKeyCompromisedFlagsTheContactsCurrentKeyByDefault() throws {
    let repo = FakeContactRepository([aliceContact])
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepository())

    try svc.markKeyCompromised(contactId: aliceContact.id, verifyKey: nil)

    #expect(repo.getById(aliceContact.id)?.revokedVerifyKeys == [aliceContact.verifyKey])
}

@Test func markKeyCompromisedIsIdempotentForAnAlreadyFlaggedKey() throws {
    let repo = FakeContactRepository([aliceContact])
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepository())
    try svc.markKeyCompromised(contactId: aliceContact.id, verifyKey: nil)

    try svc.markKeyCompromised(contactId: aliceContact.id, verifyKey: nil)

    #expect(repo.getById(aliceContact.id)?.revokedVerifyKeys == [aliceContact.verifyKey])
}

@Test func updateContactSetsKeyChangedAtOnlyWhenKeysActuallyChange() throws {
    let repo = FakeContactRepository([aliceContact])
    let svc = ContactService(contactRepository: repo, purchases: FakePurchaseRepository())
    #expect(aliceContact.keyChangedAt == nil)

    try svc.updateContact(contactId: aliceContact.id, verifyKey: Data(repeating: 0x03, count: 32), encKey: nil, newCipherSuite: nil, verificationLevel: .low)

    #expect(repo.getById(aliceContact.id)?.keyChangedAt != nil)
}

// MARK: - Custodial-heartbeat push, deposit retention, freshness

@Test func depositRetainsAnEncryptedBlobPerHolder() async throws {
    let relay = FakeShareRelay()
    let bobHolderKeys = TestKeyPair()
    let bobHolderContact = Contact(
        id: UUID(), pseudonym: "bob-holder", verifyKey: bobHolderKeys.publicKey,
        encKey: Data(repeating: 0x03, count: 32), verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let (svc, _, _, _, _, _, retainedRepo) = try makeService(relay: relay, contacts: [aliceContact, bobHolderContact])

    try await svc.deposit(secret: Data([9, 9]), label: "s", contacts: [aliceContact, bobHolderContact], threshold: 2)

    let retained = try retainedRepo.getAll()
    #expect(retained.count == 2)
    #expect(Set(retained.map(\.contactId)) == Set([aliceContact.id, bobHolderContact.id]))
}

@Test func syncDistributedStampsFreshnessAndDiscardsTheRetainedBlobOnFirstObservedApproval() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo, _, retainedRepo) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try retainedRepo.save(RetainedDepositBlob(id: depositId, secretId: secretId, contactId: aliceContact.id, label: "s", secretCreatedAt: Date(), ciphertext: Data([1]), k: 2, n: 3, mimeType: .default))
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.verifyKey, state: .approved)]

    try await svc.syncDistributed()

    let meta = try metaRepo.getAll().first { $0.id == depositId }
    #expect(meta?.lastConfirmedAt != nil)
    #expect(try retainedRepo.getAll().isEmpty)
}

@Test func syncDistributedDoesNotRefreshFreshnessOnASubsequentPollOfAnAlreadyConfirmedRow() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo, _, retainedRepo) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try retainedRepo.save(RetainedDepositBlob(id: depositId, secretId: secretId, contactId: aliceContact.id, label: "s", secretCreatedAt: Date(), ciphertext: Data([1]), k: 2, n: 3, mimeType: .default))
    relay.pending = [makeDepositRow(id: depositId, secretId: secretId, recipientKey: aliceContact.verifyKey, state: .approved)]
    try await svc.syncDistributed()
    let firstConfirmedAt = try metaRepo.getAll().first { $0.id == depositId }?.lastConfirmedAt

    // The row is still (unchangingly) approved on this second poll — an already-discarded
    // retention marker means this must not be treated as a fresh confirmation.
    try await svc.syncDistributed()

    let secondConfirmedAt = try metaRepo.getAll().first { $0.id == depositId }?.lastConfirmedAt
    #expect(firstConfirmedAt == secondConfirmedAt)
}

@Test func syncDistributedStampsFreshnessFromAnApprovedRetrieval() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, metaRepo, _, _) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try metaRepo.save(ShareMetadata(id: depositId, secretId: secretId, contactId: aliceContact.id))
    let retrievalRow = ShareRequest(
        id: UUID(), secretId: secretId, senderKey: Data(repeating: 0x05, count: 32), recipientKey: aliceContact.verifyKey,
        label: "s", secretCreatedAt: Date(), transactionType: .retrieval, state: .approved,
        requestedAt: Date(), respondedAt: Date(), ciphertext: Data([1]), k: nil, n: nil,
        senderSignature: Data(), recipientSignature: nil
    )
    relay.pending = [retrievalRow]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().first { $0.id == depositId }?.lastConfirmedAt != nil)
}

@Test func syncInboxEmitsAHeartbeatToEachDistinctSenderWhenDue() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let secretId = UUID()
    shareRepo.save(HeldShare(id: UUID(), secretId: secretId, label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.syncInbox()

    #expect(relay.pushedHeartbeats.count == 1)
    let pushed = relay.pushedHeartbeats.first
    #expect(pushed?.ownerKey == aliceContact.verifyKey)
    #expect(pushed?.secretIds == [secretId])
    #expect(pushed?.optedOut == false)
    let canon = PayloadCanonical.forHeartbeat(ownerKey: aliceContact.verifyKey, secretIds: [secretId], optedOut: false)
    #expect(bob.verify(canon, signature: pushed!.signature, publicKey: bob.verifyKey!))
}

@Test func syncInboxDoesNotReEmitAHeartbeatBeforeTheIntervalElapses() async throws {
    let relay = FakeShareRelay()
    let recentlyHeartbeatedAlice = Contact(
        id: aliceContact.id, pseudonym: aliceContact.pseudonym, verifyKey: aliceContact.verifyKey,
        encKey: aliceContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        lastHeartbeatSentAt: Date()
    )
    let (svc, _, shareRepo, _, _, _, _) = try makeService(relay: relay, contacts: [recentlyHeartbeatedAlice])
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.syncInbox()

    #expect(relay.pushedHeartbeats.isEmpty)
}

@Test func syncInboxEmitsAnOptedOutHeartbeatWithNoSecretIdsWhenEmissionIsOptedOut() async throws {
    let relay = FakeShareRelay()
    let optedOutAlice = Contact(
        id: aliceContact.id, pseudonym: aliceContact.pseudonym, verifyKey: aliceContact.verifyKey,
        encKey: aliceContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        heartbeatEmissionOptedOut: true
    )
    let (svc, _, shareRepo, _, _, _, _) = try makeService(relay: relay, contacts: [optedOutAlice])
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.syncInbox()

    #expect(relay.pushedHeartbeats.first?.optedOut == true)
    #expect(relay.pushedHeartbeats.first?.secretIds == [])
}

@Test func syncInboxDoesNotAdvanceLastHeartbeatSentAtWhenThePushFails() async throws {
    let relay = FakeShareRelay()
    relay.throwOnPushHeartbeat = true
    let (svc, _, shareRepo, contactRepo, _, _, _) = try makeService(relay: relay)
    shareRepo.save(HeldShare(id: UUID(), secretId: UUID(), label: "x", contactId: aliceContact.id, senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([1]), k: 2, n: 3, mimeType: .default))

    try await svc.syncInbox()

    #expect(contactRepo.getById(aliceContact.id)?.lastHeartbeatSentAt == nil)
}

/// Builds a signed CustodyHeartbeat notice — the signing counterpart of `relay.pushHeartbeat`.
/// `signer` is the party whose signature is attached; pass something other than the keypair
/// backing `holderKey` to build a forged notice.
private func makeSignedHeartbeat(holderKey: Data, ownerKey: Data, signer: TestKeyPair, secretIds: [UUID] = [], optedOut: Bool = false) throws -> CustodyHeartbeat {
    let canon = PayloadCanonical.forHeartbeat(ownerKey: ownerKey, secretIds: secretIds, optedOut: optedOut)
    let sig = try signer.sign(canon)
    return CustodyHeartbeat(id: UUID(), holderKey: holderKey, ownerKey: ownerKey, secretIds: secretIds, optedOut: optedOut, signature: sig, createdAt: Date())
}

@Test func syncDistributedProcessesAValidHeartbeatAndStampsFreshnessOnMatchingShares() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, metaRepo, _, retainedRepo) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try metaRepo.save(ShareMetadata(id: depositId, secretId: secretId, contactId: aliceContact.id))
    try retainedRepo.save(RetainedDepositBlob(id: depositId, secretId: secretId, contactId: aliceContact.id, label: "s", secretCreatedAt: Date(), ciphertext: Data([1]), k: 2, n: 3, mimeType: .default))
    relay.heartbeatsToReturn = [try makeSignedHeartbeat(holderKey: aliceKeys.publicKey, ownerKey: bob.verifyKey!, signer: aliceKeys, secretIds: [secretId])]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().first { $0.id == depositId }?.lastConfirmedAt != nil)
    // Heartbeat-attested confirmation also closes the retention window.
    #expect(try retainedRepo.getAll().isEmpty)
}

@Test func syncDistributedIgnoresAHeartbeatWithAForgedSignature() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, metaRepo, _, _) = try makeService(relay: relay)
    let depositId = UUID()
    let secretId = UUID()
    try metaRepo.save(ShareMetadata(id: depositId, secretId: secretId, contactId: aliceContact.id))
    // Claims to be from alice but signed by a stranger.
    relay.heartbeatsToReturn = [try makeSignedHeartbeat(holderKey: aliceKeys.publicKey, ownerKey: bob.verifyKey!, signer: strangerKeys, secretIds: [secretId])]

    try await svc.syncDistributed()

    #expect(try metaRepo.getAll().first { $0.id == depositId }?.lastConfirmedAt == nil)
}

@Test func syncDistributedSetsAndClearsHeartbeatOptedOutAt() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, contactRepo, _, _, _) = try makeService(relay: relay)
    relay.heartbeatsToReturn = [try makeSignedHeartbeat(holderKey: aliceKeys.publicKey, ownerKey: bob.verifyKey!, signer: aliceKeys, optedOut: true)]

    try await svc.syncDistributed()

    #expect(contactRepo.getById(aliceContact.id)?.heartbeatOptedOutAt != nil)

    // A subsequent non-opted-out heartbeat clears it again.
    relay.heartbeatsToReturn = [try makeSignedHeartbeat(holderKey: aliceKeys.publicKey, ownerKey: bob.verifyKey!, signer: aliceKeys, optedOut: false)]

    try await svc.syncDistributed()

    #expect(contactRepo.getById(aliceContact.id)?.heartbeatOptedOutAt == nil)
}

@Test func setHeartbeatEmissionOptedOutUpdatesTheContactAndResetsLastSentAt() throws {
    let relay = FakeShareRelay()
    let alreadySentAlice = Contact(
        id: aliceContact.id, pseudonym: aliceContact.pseudonym, verifyKey: aliceContact.verifyKey,
        encKey: aliceContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        lastHeartbeatSentAt: Date()
    )
    let (svc, _, _, contactRepo, _, _, _) = try makeService(relay: relay, contacts: [alreadySentAlice])

    try svc.setHeartbeatEmissionOptedOut(contactId: aliceContact.id, optedOut: true)

    let updated = contactRepo.getById(aliceContact.id)
    #expect(updated?.heartbeatEmissionOptedOut == true)
    #expect(updated?.lastHeartbeatSentAt == nil)
}

@Test func setHeartbeatEmissionOptedOutThrowsForAnUnknownContact() throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay)

    #expect(throws: ShareServiceError.self) {
        try svc.setHeartbeatEmissionOptedOut(contactId: UUID(), optedOut: true)
    }
}

// MARK: - Reconstruction integrity + fan-out targeting

/// A holder contact with its own real keypair — reconstruct() tests need several distinct
/// holders (unlike most of this file's single-contact fixtures), each independently able to
/// produce a validly-signed `recipientSignature` on its own retrieval response.
private struct HolderFixture {
    let keys: TestKeyPair
    let contact: Contact
}

private func makeHolderFixture(pseudonym: String) -> HolderFixture {
    let keys = TestKeyPair()
    let contact = Contact(
        id: UUID(), pseudonym: pseudonym, verifyKey: keys.publicKey,
        encKey: Data(repeating: 0x09, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    return HolderFixture(keys: keys, contact: contact)
}

/// An already-`.approved` retrieval response row, signed by the holder — mirrors what
/// `respond()` would have produced. `ciphertext` is used as-is by `NoOpShareEncryption`, so
/// passing a real `split()` share here makes it stand in directly as the "decrypted" plaintext.
private func makeApprovedRetrievalRow(secretId: UUID, holder: HolderFixture, ciphertext: Data) throws -> ShareRequest {
    let id = UUID()
    let canon = PayloadCanonical.forRespond(requestId: id, approved: true, ciphertext: ciphertext)
    let sig = try holder.keys.sign(canon)
    return ShareRequest(
        id: id, secretId: secretId, senderKey: Data(), recipientKey: holder.contact.verifyKey, label: "s",
        secretCreatedAt: Date(), transactionType: .retrieval, state: .approved,
        requestedAt: Date(), respondedAt: Date(), ciphertext: ciphertext, k: nil, n: nil,
        senderSignature: Data(), recipientSignature: sig
    )
}

/// A still-`.pending` retrieval row, as a previous `requestAll` would have left it — no
/// `recipientSignature`, because a pending row has had no response phase yet.
private func makePendingRetrievalRow(secretId: UUID, recipientKey: Data) -> ShareRequest {
    ShareRequest(
        id: UUID(), secretId: secretId, senderKey: Data(), recipientKey: recipientKey, label: "s",
        secretCreatedAt: Date(), transactionType: .retrieval, state: .pending,
        requestedAt: Date(), respondedAt: nil, ciphertext: nil, k: nil, n: nil,
        senderSignature: Data(), recipientSignature: nil
    )
}

@Test func reconstructWithExactlyKApprovedSharesHasNoIntegrityMargin() async throws {
    let relay = FakeShareRelay()
    let holders = (0..<4).map { makeHolderFixture(pseudonym: "holder\($0)") }
    let (svc, _, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay, contacts: holders.map(\.contact))
    let secretBytes: [UInt8] = Array("no margin test secret".utf8)
    let shares = try split(secret: secretBytes, shares: 4, threshold: 4)
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 4, n: 4, secretCreatedAt: Date(), state: .active))
    relay.pending = try zip(holders, shares).map { try makeApprovedRetrievalRow(secretId: secretId, holder: $0, ciphertext: Data($1)) }

    let result = try await svc.reconstruct(secretId: secretId)

    #expect(Array(result.secret) == secretBytes)
    #expect(result.integrity == .noMargin)
}

@Test func reconstructWithSurplusAllConsistentSharesIsConfirmed() async throws {
    let relay = FakeShareRelay()
    let holders = (0..<5).map { makeHolderFixture(pseudonym: "holder\($0)") }
    let (svc, _, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay, contacts: holders.map(\.contact))
    let secretBytes: [UInt8] = Array("surplus confirmed test secret".utf8)
    let shares = try split(secret: secretBytes, shares: 5, threshold: 4)
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 4, n: 5, secretCreatedAt: Date(), state: .active))
    relay.pending = try zip(holders, shares).map { try makeApprovedRetrievalRow(secretId: secretId, holder: $0, ciphertext: Data($1)) }

    let result = try await svc.reconstruct(secretId: secretId)

    #expect(Array(result.secret) == secretBytes)
    #expect(result.integrity == .confirmed)
}

@Test func reconstructExcludesATamperedShareAndStillReconstructsCorrectly() async throws {
    let relay = FakeShareRelay()
    let holders = (0..<6).map { makeHolderFixture(pseudonym: "holder\($0)") }
    let (svc, _, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay, contacts: holders.map(\.contact))
    let secretBytes: [UInt8] = Array("excluded suspect test secret".utf8)
    var shares = try split(secret: secretBytes, shares: 6, threshold: 4)
    // Simulate a compromised/corrupted holder — every secret byte wrong, x-coordinate untouched.
    for i in 0..<(shares[2].count - 1) { shares[2][i] = shares[2][i] &+ 1 }
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 4, n: 6, secretCreatedAt: Date(), state: .active))
    relay.pending = try zip(holders, shares).map { try makeApprovedRetrievalRow(secretId: secretId, holder: $0, ciphertext: Data($1)) }

    let result = try await svc.reconstruct(secretId: secretId)

    #expect(Array(result.secret) == secretBytes)
    #expect(result.integrity == .excludedSuspects(excludedContactIds: [holders[2].contact.id]))
}

@Test func reconstructThrowsWhenTooManySharesAreInconsistentToSafelyResolve() async throws {
    let relay = FakeShareRelay()
    let holders = (0..<5).map { makeHolderFixture(pseudonym: "holder\($0)") }
    let (svc, _, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay, contacts: holders.map(\.contact))
    let secretBytes: [UInt8] = Array("margin one throw test".utf8)
    var shares = try split(secret: secretBytes, shares: 5, threshold: 4)
    for i in 0..<(shares[0].count - 1) { shares[0][i] = shares[0][i] &+ 1 }
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 4, n: 5, secretCreatedAt: Date(), state: .active))
    relay.pending = try zip(holders, shares).map { try makeApprovedRetrievalRow(secretId: secretId, holder: $0, ciphertext: Data($1)) }

    do {
        _ = try await svc.reconstruct(secretId: secretId)
        Issue.record("expected ShamirError.reconstructionIntegrityFailed to be thrown")
    } catch is ShamirError {
        // expected
    }
}

@Test func requestAllTargetsOnlyConfirmedHoldersWhenTheyAlreadyMeetK() async throws {
    let relay = FakeShareRelay()
    let fresh1 = makeHolderFixture(pseudonym: "fresh1")
    let fresh2 = makeHolderFixture(pseudonym: "fresh2")
    let stale = makeHolderFixture(pseudonym: "stale")
    let (svc, _, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(
        relay: relay, contacts: [fresh1.contact, fresh2.contact, stale.contact]
    )
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 2, n: 3, secretCreatedAt: Date(), state: .active))
    let now = Date()
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: fresh1.contact.id, lastConfirmedAt: now))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: fresh2.contact.id, lastConfirmedAt: now))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: stale.contact.id, lastConfirmedAt: nil))

    try await svc.requestAll(secretId: secretId)

    let targeted = Set(relay.openedRequests.map(\.recipientKey))
    #expect(targeted == Set([fresh1.contact.verifyKey, fresh2.contact.verifyKey]))
}

@Test func requestAllWidensToEveryHolderWhenFewerThanKAreConfirmed() async throws {
    let relay = FakeShareRelay()
    let fresh = makeHolderFixture(pseudonym: "fresh")
    let stale1 = makeHolderFixture(pseudonym: "stale1")
    let stale2 = makeHolderFixture(pseudonym: "stale2")
    let (svc, _, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(
        relay: relay, contacts: [fresh.contact, stale1.contact, stale2.contact]
    )
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 2, n: 3, secretCreatedAt: Date(), state: .active))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: fresh.contact.id, lastConfirmedAt: Date()))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: stale1.contact.id, lastConfirmedAt: nil))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: stale2.contact.id, lastConfirmedAt: nil))

    try await svc.requestAll(secretId: secretId)

    let targeted = Set(relay.openedRequests.map(\.recipientKey))
    #expect(targeted == Set([fresh.contact.verifyKey, stale1.contact.verifyKey, stale2.contact.verifyKey]))
}

@Test func requestAllStillAsksAHolderWhoseSiblingAlreadyHasAnOutstandingRequest() async throws {
    let relay = FakeShareRelay()
    let standing = makeHolderFixture(pseudonym: "standing")
    let untouched = makeHolderFixture(pseudonym: "untouched")
    let (svc, _, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(
        relay: relay, contacts: [standing.contact, untouched.contact]
    )
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 2, n: 2, secretCreatedAt: Date(), state: .active))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: standing.contact.id, lastConfirmedAt: nil))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: untouched.contact.id, lastConfirmedAt: nil))
    // Neither holder is confirmed, so targeting widens to both — the case the per-secret skip
    // used to blank out entirely.
    relay.pending = [makePendingRetrievalRow(secretId: secretId, recipientKey: standing.contact.verifyKey)]

    try await svc.requestAll(secretId: secretId)

    #expect(relay.openedRequests.map(\.recipientKey) == [untouched.contact.verifyKey])
}

// MARK: - Identity regeneration (the "regenerate my own identity" trigger)

@Test func regenerateIdentityPushesASignedRotationToEveryContactAndActivatesTheNewKeys() async throws {
    let relay = FakeShareRelay()
    let charlieKeys = TestKeyPair()
    let charlieContact = Contact(
        id: UUID(), pseudonym: "charlie", verifyKey: charlieKeys.publicKey,
        encKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let (svc, bob, _, _, _, _, _) = try makeService(relay: relay, contacts: [aliceContact, charlieContact])
    let oldVerifyKey = bob.verifyKey!
    let oldEncKey = bob.encKey!

    let result = try await svc.regenerateIdentity()

    #expect(result.notifiedContacts == 2)
    #expect(result.totalContacts == 2)
    #expect(relay.pushedRotations.count == 2)
    for pushed in relay.pushedRotations {
        let canon = PayloadCanonical.forRotation(recipientKey: pushed.recipientKey, newVerifyKey: pushed.newVerifyKey, newEncKey: pushed.newEncKey, newCipherSuite: pushed.newCipherSuite)
        #expect(pushed.newCipherSuite == .current)
        // Signed by the OLD identity, proving continuity — not by the key it's rotating to.
        #expect(bob.verify(canon, signature: pushed.signature, publicKey: oldVerifyKey))
        #expect(!bob.verify(canon, signature: pushed.signature, publicKey: pushed.newVerifyKey))
    }
    // The new identity is now live.
    #expect(bob.verifyKey! != oldVerifyKey)
    #expect(bob.encKey! != oldEncKey)
}

@Test func regenerateIdentityDrainsThePendingInboxUnderTheOldIdentityBeforeRotating() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let oldVerifyKey = bob.verifyKey!
    let depositId = UUID()
    let row = try makeSignedRow(id: depositId, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
    relay.pending = [row]
    relay.byId[depositId] = row

    _ = try await svc.regenerateIdentity()

    // The deposit was picked up and its recipientSignature was produced under the OLD identity —
    // proving the drain ran (and completed) before the keys were swapped.
    #expect(shareRepo.getAll().map(\.id) == [depositId])
    let approved = try #require(relay.byId[depositId])
    #expect(approved.state == .approved)
    let sig = try #require(approved.recipientSignature)
    let canon = PayloadCanonical.forRespond(requestId: depositId, approved: true, ciphertext: nil)
    #expect(bob.verify(canon, signature: sig, publicKey: oldVerifyKey))
}

// The mid-flight rotation case, end to end: a share sealed to the encKey this device advertised at
// deposit time is still collectable after the device has rotated away from it. Uses the real
// IdentityService on both sides rather than NoOpShareEncryption, because the whole point is which
// private key the key agreement runs against.

@Test func syncInboxStillPicksUpADepositSealedToTheEncKeyRotatedAwayFrom() async throws {
    let aliceIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try aliceIdentity.register(pseudonym: "alice")
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    // Alice signs with the fixture keypair but agrees with her real X25519 key — the two keypairs
    // are independent, exactly as they are in production.
    let alice = Contact(
        id: UUID(), pseudonym: "alice", verifyKey: aliceKeys.publicKey, encKey: aliceIdentity.encKey,
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let relay = FakeShareRelay()
    let contactRepo = FakeContactRepository([alice])
    let shareRepo = FakeShareRepository()
    let purchases = FakePurchaseRepository()
    let svc = ShareService(
        relayResolver: FixedShareRelayResolver(relay),
        encryption: bobIdentity,
        shareRepository: shareRepo,
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: FakeKeyConflictRepository(),
        retainedDepositRepository: FakeRetainedDepositRepository(),
        identity: bobIdentity,
        purchases: purchases
    )

    let id = UUID()
    let share = Data("bob's share".utf8)
    let sealedToBobsOldKey = try aliceIdentity.encrypt(share, recipientEncKey: bobIdentity.encKey)
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bobIdentity.verifyKey, signer: aliceKeys, ciphertext: sealedToBobsOldKey)

    try bobIdentity.activateKeyPair(bobIdentity.generateNewKeyPair())
    relay.pending = [row]
    relay.byId[id] = row

    try await svc.syncInbox()

    #expect(shareRepo.getAll().map(\.plaintextShare) == [share])
    #expect(relay.respondCalls == [id])
}

@Test func regenerateIdentityReportsADrainThatCouldNotReachEveryRelay() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, _, _, _, _) = try makeService(relay: relay)
    let oldVerifyKey = bob.verifyKey!
    relay.unreachable = true

    let result = try await svc.regenerateIdentity()

    // Reported, not dropped — but the rotation still completes: an unreachable relay must not be
    // able to block someone rotating precisely because they think the old key is compromised.
    #expect(!result.drainSucceeded)
    #expect(bob.verifyKey! != oldVerifyKey)
}

@Test func regenerateIdentityReportsACompleteDrainWhenEveryRelayAnswers() async throws {
    let relay = FakeShareRelay()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay)

    let result = try await svc.regenerateIdentity()

    #expect(result.drainSucceeded)
}

@Test func regenerateIdentityStillActivatesTheNewKeysWhenOneContactsRelayIsUnreachable() async throws {
    let byorUrl = "http://byor.example:9000"
    let charlieKeys = TestKeyPair()
    let charlieContact = Contact(
        id: UUID(), pseudonym: "charlie", verifyKey: charlieKeys.publicKey,
        encKey: Data(repeating: 0x02, count: 32),
        verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        relayBaseUrl: byorUrl
    )
    let defaultRelay = FakeShareRelay()
    let byorRelay = FakeShareRelay()
    byorRelay.throwOnPushRotation = true
    let bobIdentity = IdentityService(identityStore: InMemoryIdentityStoreForShareServiceTest())
    try bobIdentity.register(pseudonym: "bob")
    let contactRepo = FakeContactRepository([aliceContact, charlieContact])
    let purchases = FakePurchaseRepository()
    let svc = ShareService(
        relayResolver: TwoRelayResolver(default: defaultRelay, byorUrl: byorUrl, byor: byorRelay),
        encryption: NoOpShareEncryption(),
        shareRepository: FakeShareRepository(),
        shareMetadataRepository: FakeShareMetadataRepository(),
        secretRepository: FakeSecretRepository(),
        contactRepository: contactRepo,
        contactManagement: ContactService(contactRepository: contactRepo, purchases: purchases),
        keyConflictRepository: FakeKeyConflictRepository(),
        retainedDepositRepository: FakeRetainedDepositRepository(),
        identity: bobIdentity,
        purchases: purchases
    )
    let oldVerifyKey = bobIdentity.verifyKey

    let result = try await svc.regenerateIdentity()

    #expect(result.totalContacts == 2)
    #expect(result.notifiedContacts == 1) // charlie's BYOR relay refused the push
    #expect(defaultRelay.pushedRotations.count == 1)
    #expect(byorRelay.pushedRotations.isEmpty)
    // The swap still completes even though one contact couldn't be notified.
    #expect(bobIdentity.verifyKey != oldVerifyKey)
}

@Test func requestAllTreatsAHeartbeatOptedOutHolderAsNotConfirmedEvenWithARecentTimestamp() async throws {
    let relay = FakeShareRelay()
    let optedOutButRecent = makeHolderFixture(pseudonym: "optedOut")
    var optedOutContact = optedOutButRecent.contact
    optedOutContact = Contact(
        id: optedOutContact.id, pseudonym: optedOutContact.pseudonym, verifyKey: optedOutContact.verifyKey,
        encKey: optedOutContact.encKey, verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date(),
        heartbeatOptedOutAt: Date()
    )
    let other = makeHolderFixture(pseudonym: "other")
    let (svc, _, _, secretRepo, metaRepo, _) = try makeServiceForRecoveryTest(
        relay: relay, contacts: [optedOutContact, other.contact]
    )
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: .default, k: 2, n: 2, secretCreatedAt: Date(), state: .active))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: optedOutContact.id, lastConfirmedAt: Date()))
    try metaRepo.save(ShareMetadata(id: UUID(), secretId: secretId, contactId: other.contact.id, lastConfirmedAt: nil))

    try await svc.requestAll(secretId: secretId)

    // Only 1 of 2 holders is genuinely confirmed (< k=2), so targeting widens to everyone.
    let targeted = Set(relay.openedRequests.map(\.recipientKey))
    #expect(targeted == Set([optedOutContact.verifyKey, other.contact.verifyKey]))
}

// MARK: - secret size and format

@Test func depositAcceptsASecretExactlyAtTheLimit() async throws {
    let relay = FakeShareRelay()
    let holderKeys = TestKeyPair()
    let holderContact = Contact(
        id: UUID(), pseudonym: "holder", verifyKey: holderKeys.publicKey,
        encKey: Data(repeating: 0x03, count: 32), verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [aliceContact, holderContact])
    let secret = Data(repeating: 0x41, count: SecretLimits.maxSecretBytes)

    try await svc.deposit(secret: secret, label: "s", contacts: [aliceContact, holderContact], threshold: 2)

    #expect(relay.openedRequests.count == 2)
}

@Test func depositRefusesASecretOneByteOverTheLimit() async throws {
    let relay = FakeShareRelay()
    let holderKeys = TestKeyPair()
    let holderContact = Contact(
        id: UUID(), pseudonym: "holder", verifyKey: holderKeys.publicKey,
        encKey: Data(repeating: 0x03, count: 32), verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [aliceContact, holderContact])
    let secret = Data(repeating: 0x41, count: SecretLimits.maxSecretBytes + 1)

    await #expect(throws: ShareServiceError.self) {
        try await svc.deposit(secret: secret, label: "s", contacts: [aliceContact, holderContact], threshold: 2)
    }
    // Nothing reached the relay — the guard runs before the split, not after it.
    #expect(relay.openedRequests.isEmpty)
}

@Test func sniffedRecognisesPngAndJpegAndNothingElse() {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [0x00, 0x01])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    #expect(MimeType.sniffed(png) == .png)
    #expect(MimeType.sniffed(jpeg) == .jpeg)
    #expect(MimeType.sniffed(Data("hello".utf8)) == nil)
    #expect(MimeType.sniffed(Data([0x47, 0x49, 0x46, 0x38])) == nil) // GIF is deliberately not accepted
}

@Test func sniffedDoesNotOverrunABufferShorterThanTheMagicBytes() {
    #expect(MimeType.sniffed(Data()) == nil)
    #expect(MimeType.sniffed(Data([0xFF])) == nil)
    #expect(MimeType.sniffed(Data([0xFF, 0xD8])) == nil)
    #expect(MimeType.sniffed(Data([0x89, 0x50, 0x4E])) == nil)
}

// MARK: - mimeType

@Test func depositRecordsTheMimeTypeOnTheSecretAndSignsItIntoEveryDepositRow() async throws {
    let relay = FakeShareRelay()
    let holderKeys = TestKeyPair()
    let holderContact = Contact(
        id: UUID(), pseudonym: "holder", verifyKey: holderKeys.publicKey,
        encKey: Data(repeating: 0x03, count: 32), verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    let (svc, _, _, _, _, _, retainedRepo) = try makeService(relay: relay, contacts: [aliceContact, holderContact])

    try await svc.deposit(secret: Data([1, 2, 3]), label: "s", contacts: [aliceContact, holderContact], threshold: 2, mimeType: MimeType("image/png"))

    #expect(relay.openedRequests.allSatisfy { $0.mimeType == MimeType("image/png") })
    #expect(try retainedRepo.getAll().allSatisfy { $0.mimeType == MimeType("image/png") })
}

@Test func syncInboxCarriesTheDepositedMimeTypeOntoTheHeldShare() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let row = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys, mimeType: MimeType("image/png"))
    relay.pending = [row]
    relay.byId = [id: row]

    try await svc.syncInbox()

    #expect(shareRepo.getAll().map(\.mimeType) == [MimeType("image/png")])
}

/// A deposit whose `mimeType` is absent cannot come from a conforming relay, and storing the share
/// without one would leave the holder unable to report it during the owner's recovery — so the
/// pickup is skipped and retried, exactly as it is for a missing `k`/`n`.
@Test func syncInboxLeavesADepositPendingWhenTheMimeTypeIsMissing() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let signed = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
    // Re-sign without the mimeType so the row is internally consistent and only the guard rejects it.
    let canon = PayloadCanonical.forOpen(secretId: signed.secretId, transactionType: .deposit, recipientKey: signed.recipientKey, label: signed.label, secretCreatedAt: signed.secretCreatedAt, ciphertext: signed.ciphertext, k: signed.k, n: signed.n, mimeType: nil)
    let row = ShareRequest(
        id: id, secretId: signed.secretId, senderKey: signed.senderKey, recipientKey: signed.recipientKey,
        label: signed.label, secretCreatedAt: signed.secretCreatedAt, transactionType: .deposit, state: .pending,
        requestedAt: Date(), respondedAt: nil, ciphertext: signed.ciphertext,
        k: signed.k, n: signed.n, mimeType: nil, senderSignature: try aliceKeys.sign(canon), recipientSignature: nil
    )
    relay.pending = [row]
    relay.byId = [id: row]

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

@Test func pushRecoveryMetadataReportsTheMimeTypeOfTheShareItHolds() async throws {
    let relay = FakeShareRelay()
    let (svc, _, shareRepo, _, _, _) = try makeServiceForRecoveryTest(relay: relay)
    shareRepo.save(HeldShare(
        id: UUID(), secretId: UUID(), label: "test secret", contactId: aliceContact.id,
        senderPseudonym: "alice", createdAt: Date(), pickedUpAt: Date(), plaintextShare: Data([9]),
        k: 2, n: 3, mimeType: MimeType("image/jpeg")
    ))

    try await svc.pushRecoveryMetadata(contactId: aliceContact.id)

    #expect(relay.openedRequests.first?.mimeType == MimeType("image/jpeg"))
}

@Test func syncInboxRebuildsASecretWithTheMimeTypeTheHolderReports() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay)
    let secretId = UUID()
    relay.pending = [try makeApprovedRecoveryMetadataRow(secretId: secretId, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys, mimeType: MimeType("image/png"))]

    try await svc.syncInbox()

    #expect(try secretRepo.getAll().map(\.mimeType) == [MimeType("image/png")])
}

@Test func reconstructReportsTheMimeTypeTheOwnerRecordedForTheSecret() async throws {
    let relay = FakeShareRelay()
    let holders = (0..<2).map { makeHolderFixture(pseudonym: "holder\($0)") }
    let (svc, _, _, secretRepo, _, _) = try makeServiceForRecoveryTest(relay: relay, contacts: holders.map(\.contact))
    let secretBytes: [UInt8] = Array("mime round trip".utf8)
    let shares = try split(secret: secretBytes, shares: 2, threshold: 2)
    let secretId = UUID()
    try secretRepo.save(Secret(id: secretId, label: "s", mimeType: MimeType("image/png"), k: 2, n: 2, secretCreatedAt: Date(), state: .active))
    relay.pending = try zip(holders, shares).map { try makeApprovedRetrievalRow(secretId: secretId, holder: $0, ciphertext: Data($1)) }

    let result = try await svc.reconstruct(secretId: secretId)

    #expect(Array(result.secret) == secretBytes)
    #expect(result.mimeType == MimeType("image/png"))
}

/// `mimeType` rides inside `senderSignature`, so a relay that rewrote it — pointing a text secret at
/// an image decoder, say — invalidates the row rather than changing how it renders. The holder skips
/// it silently, as it does any deposit whose signature does not verify.
@Test func syncInboxSkipsADepositWhoseMimeTypeWasAlteredAfterSigning() async throws {
    let relay = FakeShareRelay()
    let (svc, bob, shareRepo, _, _, _, _) = try makeService(relay: relay)
    let id = UUID()
    let signed = try makeSignedRow(id: id, senderKey: aliceKeys.publicKey, recipientKey: bob.verifyKey!, signer: aliceKeys)
    let tampered = ShareRequest(
        id: signed.id, secretId: signed.secretId, senderKey: signed.senderKey, recipientKey: signed.recipientKey,
        label: signed.label, secretCreatedAt: signed.secretCreatedAt, transactionType: .deposit, state: .pending,
        requestedAt: signed.requestedAt, respondedAt: nil, ciphertext: signed.ciphertext,
        k: signed.k, n: signed.n, mimeType: MimeType("image/png"),
        senderSignature: signed.senderSignature, recipientSignature: nil
    )
    relay.pending = [tampered]
    relay.byId = [id: tampered]

    try await svc.syncInbox()

    #expect(relay.respondCalls.isEmpty)
    #expect(shareRepo.getAll().isEmpty)
}

/// Classification tolerates the shapes a real `Content-Type` takes — parameters and casing — while
/// the value itself stays byte-exact, because it is what the sender signed.
@Test func mimeTypeClassifiesIgnoringCaseAndParametersWithoutRewritingItsValue() {
    let declared = MimeType("Text/Plain; charset=utf-8")
    #expect(declared.isText)
    #expect(!declared.isImage)
    #expect(declared.value == "Text/Plain; charset=utf-8")
    #expect(MimeType("image/PNG").isImage)
    #expect(!MimeType("application/octet-stream").isText)
    #expect(!MimeType("application/octet-stream").isImage)
}

// MARK: - free tier

// The cap counts *active* secrets rather than lifetime deposits, so these care about what
// `listSecrets` reports afterwards, not about how many rows the relay saw.

private func holderPair() -> (Contact, Contact) {
    let holderKeys = TestKeyPair()
    let holder = Contact(
        id: UUID(), pseudonym: "holder", verifyKey: holderKeys.publicKey,
        encKey: Data(repeating: 0x03, count: 32), verificationLevel: .veryHigh, verifiedAt: nil, addedAt: Date()
    )
    return (aliceContact, holder)
}

@Test func depositRefusesOneSecretPastTheFreeTierCap() async throws {
    let relay = FakeShareRelay()
    let (alice, holder) = holderPair()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [alice, holder])
    for i in 0..<SecretLimits.freeTierMaxActiveSecrets {
        try await svc.deposit(secret: Data([1, 2, 3]), label: "s\(i)", contacts: [alice, holder], threshold: 2)
    }

    do {
        try await svc.deposit(secret: Data([4, 5, 6]), label: "one too many", contacts: [alice, holder], threshold: 2)
        Issue.record("expected the free-tier cap to refuse a fourth secret")
    } catch let ShareServiceError.freeTierLimitReached(active, limit) {
        #expect(active == SecretLimits.freeTierMaxActiveSecrets)
        #expect(limit == SecretLimits.freeTierMaxActiveSecrets)
    }

    #expect(try svc.listSecrets().count == SecretLimits.freeTierMaxActiveSecrets)
}

@Test func premiumLiftsTheFreeTierCap() async throws {
    let relay = FakeShareRelay()
    let (alice, holder) = holderPair()
    let purchases = FakePurchaseRepository()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [alice, holder], purchases: purchases)
    for i in 0..<SecretLimits.freeTierMaxActiveSecrets {
        try await svc.deposit(secret: Data([1, 2, 3]), label: "s\(i)", contacts: [alice, holder], threshold: 2)
    }

    purchases.premium = true
    try await svc.deposit(secret: Data([4, 5, 6]), label: "the fourth", contacts: [alice, holder], threshold: 2)

    #expect(try svc.listSecrets().count == SecretLimits.freeTierMaxActiveSecrets + 1)
}

@Test func discardingASecretFreesASlotBeforeAnyHolderConfirms() async throws {
    let relay = FakeShareRelay()
    let (alice, holder) = holderPair()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [alice, holder])
    for i in 0..<SecretLimits.freeTierMaxActiveSecrets {
        try await svc.deposit(secret: Data([1, 2, 3]), label: "s\(i)", contacts: [alice, holder], threshold: 2)
    }

    // The record survives until every holder confirms removal; the slot does not wait for that.
    try await svc.discardSecret(secretId: try #require(svc.listSecrets().first).id)
    try await svc.deposit(secret: Data([4, 5, 6]), label: "the replacement", contacts: [alice, holder], threshold: 2)

    #expect(try svc.listSecrets().filter { $0.state == .discarding }.count == 1)
    #expect(try svc.listSecrets().filter { $0.state == .active }.count == SecretLimits.freeTierMaxActiveSecrets)
}

@Test func aRepairReSplitIsExemptFromTheFreeTierCap() async throws {
    let relay = FakeShareRelay()
    let (alice, holder) = holderPair()
    let (svc, _, _, _, _, _, _) = try makeService(relay: relay, contacts: [alice, holder])
    for i in 0..<SecretLimits.freeTierMaxActiveSecrets {
        try await svc.deposit(secret: Data([1, 2, 3]), label: "s\(i)", contacts: [alice, holder], threshold: 2)
    }
    let degraded = try #require(svc.listSecrets().first)

    // Repair deposits the replacement before discarding the original, so at the cap both exist at
    // once. Refusing that would leave a free user's only way out of a degrading secret the one
    // that destroys it first.
    try await svc.deposit(secret: Data([1, 2, 3]), label: degraded.label, contacts: [alice, holder], threshold: 2, replacing: degraded.id)

    #expect(try svc.listSecrets().count == SecretLimits.freeTierMaxActiveSecrets + 1)
}
