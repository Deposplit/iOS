import CryptoKit
import Testing
@testable import hexagon
import Foundation

/// In-memory IdentityStore — no Keychain access needed for these tests.
private final class InMemoryIdentityStore: IdentityStore {
    private(set) var isRegistered = false
    private var _pseudonym = ""
    private var _verifyKey = Data()
    private var _signKey = Data()
    private var _encKey = Data()
    private var _decKey = Data()
    private var _previousDecKey: Data?
    private var _identityCreatedAt: Date?

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
        // Mirrors the real adapters: registration starts a new identity, rotation continues one.
        self._identityCreatedAt = Date()
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
    var identityCreatedAt: Date? { _identityCreatedAt }
    func previousDecKey() -> Data? { _previousDecKey }
}

private func newIdentity() throws -> IdentityService {
    let svc = IdentityService(identityStore: InMemoryIdentityStore())
    try svc.register(pseudonym: "test")
    return svc
}

// Mirrors deposplit.com's PublicKeyTests valid/tampered/wrong-key trio, for
// IdentityService.verify — the recipient-side counterpart of the server's PublicKey.verify,
// used to independently re-verify senderSignature/recipientSignature (see PayloadCanonical).

@Test func verifyReturnsTrueForAValidSignature() throws {
    let alice = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    #expect(alice.verify(message, signature: sig, publicKey: alice.verifyKey!))
}

@Test func verifyReturnsFalseForATamperedMessage() throws {
    let alice = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    let tampered = Data("hello depospliz".utf8)
    #expect(!alice.verify(tampered, signature: sig, publicKey: alice.verifyKey!))
}

@Test func verifyReturnsFalseWhenCheckedAgainstADifferentKey() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    #expect(!bob.verify(message, signature: sig, publicKey: bob.verifyKey!))
}

// -------------------------------------------------------------------------
// generateNewKeyPair() / activateKeyPair() — the identity-regeneration trigger
// -------------------------------------------------------------------------

@Test func generateNewKeyPairDoesNotTouchStorage() throws {
    let alice = try newIdentity()
    let originalVerifyKey = alice.verifyKey!
    let originalEncKey = alice.encKey!
    let candidate = alice.generateNewKeyPair()
    #expect(candidate.verifyKey != originalVerifyKey)
    #expect(candidate.encKey != originalEncKey)
    // Unpersisted — the live identity hasn't moved.
    #expect(alice.verifyKey! == originalVerifyKey)
    #expect(alice.encKey! == originalEncKey)
}

@Test func activateKeyPairPersistsTheNewKeysAndPreservesThePseudonym() throws {
    let alice = try newIdentity()
    let candidate = alice.generateNewKeyPair()
    try alice.activateKeyPair(candidate)
    #expect(alice.verifyKey! == candidate.verifyKey)
    #expect(alice.encKey! == candidate.encKey)
    #expect(alice.pseudonym == "test")
}

// A share is sealed to whichever encKey the holder advertised at deposit time. If rotating
// destroyed the matching decKey outright, a holder who rotates between a deposit and their pickup
// could never collect it — the row would stay pending and every later poll would fail identically.

@Test func decryptFallsBackToTheDecKeyDisplacedByTheLastRotation() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealedToAlicesOldKey = try bob.encrypt(Data("one share".utf8), recipientEncKey: alice.encKey!)

    try alice.activateKeyPair(alice.generateNewKeyPair())

    #expect(try alice.decrypt(sealedToAlicesOldKey) == Data("one share".utf8))
}

@Test func decryptDoesNotReachBackPastOneGeneration() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealedToAlicesOldestKey = try bob.encrypt(Data("one share".utf8), recipientEncKey: alice.encKey!)

    try alice.activateKeyPair(alice.generateNewKeyPair())
    try alice.activateKeyPair(alice.generateNewKeyPair())

    // Deliberate: one generation covers the deposit-to-pickup window, and no more key material
    // than that lingers at rest.
    #expect(throws: (any Error).self) {
        try alice.decrypt(sealedToAlicesOldestKey)
    }
}

@Test func sealingInvolvesNoKeyOfTheSendersOwn() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealedBeforeAlicesRotations = try alice.encrypt(Data("outgoing".utf8), recipientEncKey: bob.encKey!)
    try alice.activateKeyPair(alice.generateNewKeyPair())
    try alice.activateKeyPair(alice.generateNewKeyPair())

    // Bob never needs Alice's key to open it, so however often she rotates, what she sealed opens.
    #expect(try bob.decrypt(sealedBeforeAlicesRotations) == Data("outgoing".utf8))
}

// The property the retained deposits rest on: a box sealed for a holder stays closed to the owner.
@Test func aSenderCannotOpenABoxSheSealedForSomebodyElse() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealed = try alice.encrypt(Data("Bob's share".utf8), recipientEncKey: bob.encKey!)

    #expect(throws: (any Error).self) { try alice.decrypt(sealed) }
}

@Test func aBoxIsTheTagTheEncapsulatedKeyAndTheCiphertextWithAFreshEphemeralKeyEachTime() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let plaintext = Data("shhh".utf8)
    let first = try alice.encrypt(plaintext, recipientEncKey: bob.encKey!)
    let second = try alice.encrypt(plaintext, recipientEncKey: bob.encKey!)

    #expect(first.count == 1 + 32 + plaintext.count + 16)
    #expect(first.dropFirst().prefix(32) != second.dropFirst().prefix(32))
}

@Test func registeringAFreshIdentityDropsTheRetainedKey() throws {
    let store = InMemoryIdentityStore()
    let alice = IdentityService(identityStore: store)
    try alice.register(pseudonym: "test")
    let bob = try newIdentity()
    let sealedToAlicesOldKey = try bob.encrypt(Data("one share".utf8), recipientEncKey: alice.encKey!)
    try alice.activateKeyPair(alice.generateNewKeyPair())

    // Registration is a new identity, not a continuation of the old one, so nothing carries over.
    try alice.register(pseudonym: "test")

    #expect(throws: (any Error).self) {
        try alice.decrypt(sealedToAlicesOldKey)
    }
}

@Test func signAfterActivateKeyPairVerifiesAgainstTheNewKeyNotTheOld() throws {
    let alice = try newIdentity()
    let oldVerifyKey = alice.verifyKey!
    let candidate = alice.generateNewKeyPair()
    try alice.activateKeyPair(candidate)
    let message = Data("post-rotation message".utf8)
    let sig = try alice.sign(message)
    #expect(alice.verify(message, signature: sig, publicKey: candidate.verifyKey))
    #expect(!alice.verify(message, signature: sig, publicKey: oldVerifyKey))
}

// -------------------------------------------------------------------------
// encrypt() / decrypt() — the per-message TransportSuite tag
// -------------------------------------------------------------------------

@Test func encryptThenDecryptRoundTrips() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let plaintext = Data("shhh".utf8)
    let ciphertext = try alice.encrypt(plaintext, recipientEncKey: bob.encKey!)
    let decrypted = try bob.decrypt(ciphertext)
    #expect(decrypted == plaintext)
}

@Test func encryptPrependsTheCurrentTransportSuiteTag() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let ciphertext = try alice.encrypt(Data("shhh".utf8), recipientEncKey: bob.encKey!)
    #expect(ciphertext.first == TransportSuite.current.rawValue)
}

@Test func decryptThrowsUnsupportedForAnUnrecognizedSuiteTag() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    var ciphertext = try alice.encrypt(Data("shhh".utf8), recipientEncKey: bob.encKey!)
    ciphertext[ciphertext.startIndex] = 0xFF
    do {
        _ = try bob.decrypt(ciphertext)
        Issue.record("expected TransportSuiteError.unsupported")
    } catch TransportSuiteError.unsupported(let tag) {
        #expect(tag == 0xFF)
    }
}

// -------------------------------------------------------------------------
// Sealed labels — the same box as a share, under a key derivation of its own
// -------------------------------------------------------------------------

@Test func sealLabelThenOpenLabelRoundTrips() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealed = try alice.sealLabel("Bitcoin seed 🔑", recipientEncKey: bob.encKey!)
    #expect(sealed.first == TransportSuite.current.rawValue)
    #expect(try bob.openLabel(sealed) == "Bitcoin seed 🔑")
}

@Test func aSealedLabelDoesNotCarryItsTextInTheClear() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealed = try alice.sealLabel("Bitcoin seed", recipientEncKey: bob.encKey!)
    #expect(sealed.range(of: Data("Bitcoin seed".utf8)) == nil)
}

@Test func aShareBoxDoesNotOpenAsALabelNorALabelBoxAsAShare() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let shareBox = try alice.encrypt(Data("one share".utf8), recipientEncKey: bob.encKey!)
    let labelBox = try alice.sealLabel("one label", recipientEncKey: bob.encKey!)
    #expect(throws: (any Error).self) { try bob.openLabel(shareBox) }
    #expect(throws: (any Error).self) { try bob.decrypt(labelBox) }
}

@Test func openLabelFallsBackToTheDecKeyDisplacedByTheLastRotation() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let sealedToAlicesOldKey = try bob.sealLabel("passport", recipientEncKey: alice.encKey!)

    try alice.activateKeyPair(alice.generateNewKeyPair())

    #expect(try alice.openLabel(sealedToAlicesOldKey) == "passport")
}

// -------------------------------------------------------------------------
// Cross-platform box vectors — the same four boxes, sealed once by CryptoKit and once by
// BouncyCastle to one fixed recipient key, are opened by iOS, Android and phon alike. HPKE draws a
// fresh ephemeral key per box, so a box cannot be reproduced byte for byte; what each platform
// proves is that it opens what the other library sealed. Identical fixtures are checked into
// Android's IdentityServiceVerifyTest.kt and phon's IdentityServiceVerifyTests.scala.
// -------------------------------------------------------------------------

private let vectorRecipientDecKey = Data((0x20...0x3f).map { UInt8($0) })
private let vectorRecipientEncKey = Data(hex: "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
private let cryptoKitShareBox = Data(hex: "028645dabe9fc9135324fc4b60c60d562a5b91cbba3a4e7767363138c411154465cfaff103793c5427240d1c797a5c7f3019b453158117d32c409c073aa86d828ce754b2")
private let cryptoKitLabelBox = Data(hex: "02182112460138f7f6314a553918a4f46d85148ccd8a7ab322c0cb2eb34ac97f528f0673b03dac84898ee14fbc6cff3c2318acb1fe4ef3d036a797f294ce8cef4274")
private let bouncyCastleShareBox = Data(hex: "02b09f312abb31cbf78fc7c41f3912006d25d966d2be78a376bd388cdd30e685446a75dadf1450dade7e955dd6879fa1e9fd1aa7e62e721912fa5bcec7854e7397b80767")
private let bouncyCastleLabelBox = Data(hex: "02e859635cccd28e42b3f26bfacdf98db69242fd81c5faa67dec62de46714b270f48bdce7f66c707226e73396b84cb1d9fa4e5b9cf7b008df9fed2163a14f8be83fc")

private func vectorRecipient() throws -> IdentityService {
    let recipient = try newIdentity()
    let current = recipient.generateNewKeyPair()
    try recipient.activateKeyPair(KeyPairMaterial(
        verifyKey: current.verifyKey, signKey: current.signKey,
        encKey: vectorRecipientEncKey, decKey: vectorRecipientDecKey
    ))
    return recipient
}

@Test func theFixedRecipientKeyDerivesTheFixedPublicKey() throws {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: vectorRecipientDecKey)
    #expect(key.publicKey.rawRepresentation == vectorRecipientEncKey)
}

@Test func theCryptoKitVectorBoxesOpen() throws {
    let recipient = try vectorRecipient()
    #expect(try recipient.decrypt(cryptoKitShareBox) == Data("a share of a secret".utf8))
    #expect(try recipient.openLabel(cryptoKitLabelBox) == "Bitcoin seed 🔑")
}

@Test func theBouncyCastleVectorBoxesOpen() throws {
    let recipient = try vectorRecipient()
    #expect(try recipient.decrypt(bouncyCastleShareBox) == Data("a share of a secret".utf8))
    #expect(try recipient.openLabel(bouncyCastleLabelBox) == "Bitcoin seed 🔑")
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
