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

    #expect(try alice.decrypt(sealedToAlicesOldKey, recipientEncKey: bob.encKey!) == Data("one share".utf8))
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
        try alice.decrypt(sealedToAlicesOldestKey, recipientEncKey: bob.encKey!)
    }
}

@Test func encryptNeverSealsUnderTheDisplacedKey() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let alicesOldEncKey = alice.encKey!
    try alice.activateKeyPair(alice.generateNewKeyPair())

    let sealed = try alice.encrypt(Data("outgoing".utf8), recipientEncKey: bob.encKey!)

    #expect(try bob.decrypt(sealed, recipientEncKey: alice.encKey!) == Data("outgoing".utf8))
    #expect(throws: (any Error).self) {
        try bob.decrypt(sealed, recipientEncKey: alicesOldEncKey)
    }
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
        try alice.decrypt(sealedToAlicesOldKey, recipientEncKey: bob.encKey!)
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
    let decrypted = try bob.decrypt(ciphertext, recipientEncKey: alice.encKey!)
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
        _ = try bob.decrypt(ciphertext, recipientEncKey: alice.encKey!)
        Issue.record("expected TransportSuiteError.unsupported")
    } catch TransportSuiteError.unsupported(let tag) {
        #expect(tag == 0xFF)
    }
}
