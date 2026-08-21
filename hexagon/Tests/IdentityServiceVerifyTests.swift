import Testing
@testable import hexagon
import Foundation

/// In-memory IdentityStore — no Keychain access needed for these tests.
private final class InMemoryIdentityStore: IdentityStore {
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
    #expect(alice.verify(message, signature: sig, publicKey: alice.edPublicKey))
}

@Test func verifyReturnsFalseForATamperedMessage() throws {
    let alice = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    let tampered = Data("hello depospliz".utf8)
    #expect(!alice.verify(tampered, signature: sig, publicKey: alice.edPublicKey))
}

@Test func verifyReturnsFalseWhenCheckedAgainstADifferentKey() throws {
    let alice = try newIdentity()
    let bob = try newIdentity()
    let message = Data("hello deposplit".utf8)
    let sig = try alice.sign(message)
    #expect(!bob.verify(message, signature: sig, publicKey: bob.edPublicKey))
}

// -------------------------------------------------------------------------
// generateNewKeyPair() / activateKeyPair() — item 9's identity-regen trigger
// -------------------------------------------------------------------------

@Test func generateNewKeyPairDoesNotTouchStorage() throws {
    let alice = try newIdentity()
    let originalEdKey = alice.edPublicKey
    let originalXKey = alice.xPublicKey
    let candidate = alice.generateNewKeyPair()
    #expect(candidate.edPublicKey != originalEdKey)
    #expect(candidate.xPublicKey != originalXKey)
    // Unpersisted — the live identity hasn't moved.
    #expect(alice.edPublicKey == originalEdKey)
    #expect(alice.xPublicKey == originalXKey)
}

@Test func activateKeyPairPersistsTheNewKeysAndPreservesThePseudonym() throws {
    let alice = try newIdentity()
    let candidate = alice.generateNewKeyPair()
    try alice.activateKeyPair(candidate)
    #expect(alice.edPublicKey == candidate.edPublicKey)
    #expect(alice.xPublicKey == candidate.xPublicKey)
    #expect(alice.pseudonym == "test")
}

@Test func signAfterActivateKeyPairVerifiesAgainstTheNewKeyNotTheOld() throws {
    let alice = try newIdentity()
    let oldEdKey = alice.edPublicKey
    let candidate = alice.generateNewKeyPair()
    try alice.activateKeyPair(candidate)
    let message = Data("post-rotation message".utf8)
    let sig = try alice.sign(message)
    #expect(alice.verify(message, signature: sig, publicKey: candidate.edPublicKey))
    #expect(!alice.verify(message, signature: sig, publicKey: oldEdKey))
}
