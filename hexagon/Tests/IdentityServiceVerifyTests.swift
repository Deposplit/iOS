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

    var pseudonym: String { _pseudonym }
    var verifyKey: Data { _verifyKey }
    var encKey: Data { _encKey }

    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws {
        self._pseudonym = pseudonym
        self._verifyKey = verifyKey
        self._signKey = signKey
        self._encKey = encKey
        self._decKey = decKey
        self.isRegistered = true
    }

    func signKey() throws -> Data { _signKey }
    func decKey() throws -> Data { _decKey }
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
    #expect(alice.verify(message, signature: sig, publicKey: alice.verifyKey))
}

@Test func verifyReturnsFalseForATamperedMessage() throws {
    let alice = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    let tampered = Data("hello depospliz".utf8)
    #expect(!alice.verify(tampered, signature: sig, publicKey: alice.verifyKey))
}

@Test func verifyReturnsFalseWhenCheckedAgainstADifferentKey() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    #expect(!bob.verify(message, signature: sig, publicKey: bob.verifyKey))
}

// -------------------------------------------------------------------------
// generateNewKeyPair() / activateKeyPair() — the identity-regeneration trigger
// -------------------------------------------------------------------------

@Test func generateNewKeyPairDoesNotTouchStorage() throws {
    let alice = try newIdentity()
    let originalVerifyKey = alice.verifyKey
    let originalEncKey = alice.encKey
    let candidate = alice.generateNewKeyPair()
    #expect(candidate.verifyKey != originalVerifyKey)
    #expect(candidate.encKey != originalEncKey)
    // Unpersisted — the live identity hasn't moved.
    #expect(alice.verifyKey == originalVerifyKey)
    #expect(alice.encKey == originalEncKey)
}

@Test func activateKeyPairPersistsTheNewKeysAndPreservesThePseudonym() throws {
    let alice = try newIdentity()
    let candidate = alice.generateNewKeyPair()
    try alice.activateKeyPair(candidate)
    #expect(alice.verifyKey == candidate.verifyKey)
    #expect(alice.encKey == candidate.encKey)
    #expect(alice.pseudonym == "test")
}

@Test func signAfterActivateKeyPairVerifiesAgainstTheNewKeyNotTheOld() throws {
    let alice = try newIdentity()
    let oldVerifyKey = alice.verifyKey
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
    let ciphertext = try alice.encrypt(plaintext, recipientEncKey: bob.encKey)
    let decrypted = try bob.decrypt(ciphertext, recipientEncKey: alice.encKey)
    #expect(decrypted == plaintext)
}

@Test func encryptPrependsTheCurrentTransportSuiteTag() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let ciphertext = try alice.encrypt(Data("shhh".utf8), recipientEncKey: bob.encKey)
    #expect(ciphertext.first == TransportSuite.current.rawValue)
}

@Test func decryptThrowsUnsupportedForAnUnrecognizedSuiteTag() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    var ciphertext = try alice.encrypt(Data("shhh".utf8), recipientEncKey: bob.encKey)
    ciphertext[ciphertext.startIndex] = 0xFF
    do {
        _ = try bob.decrypt(ciphertext, recipientEncKey: alice.encKey)
        Issue.record("expected TransportSuiteError.unsupported")
    } catch TransportSuiteError.unsupported(let tag) {
        #expect(tag == 0xFF)
    }
}
