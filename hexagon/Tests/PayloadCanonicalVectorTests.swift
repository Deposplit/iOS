import Testing
@testable import hexagon
import Foundation
import CryptoKit

// Cross-platform interop vector for PayloadCanonical.forOpen's byte construction — mirrors the
// existing hand-derived SSS test vectors (ShamirTest.kt / ShamirSecretSharingTests.swift).
// Ed25519 sign/verify interop across BouncyCastle/CryptoKit is already proven via the
// transport-auth signature; what this vector
// actually exercises is the *canonical byte construction* itself — a field-order or encoding
// slip on any one platform would silently produce a different signature than the other two even
// though each platform's own sign/verify round-trips fine internally.
//
// Identical fixed inputs, keypair, and expected outputs are checked into
// deposplit.com/hexagons/relay/src/test/scala/value_objects/PayloadCanonicalVectorTests.scala and
// Android/hexagon/src/test/kotlin/com/deposplit/value_objects/PayloadCanonicalVectorTest.kt. All
// three must produce byte-identical canonical bytes and the same signature for the same 32-byte
// private key seed.

// Private key seed: bytes 0x00..0x1f. Not a real identity — a fixed, reproducible fixture.
private let privateKeySeed = Data((0..<32).map { UInt8($0) })
private let expectedPublicKeyBase64Url = "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg"
private let expectedSignatureBase64Url = "WFKVgN38zr_3fiLZ1UpxnrvUoW0KA-XjD1ml-VyfITDuCMv9D9uT0ryaHCiHYtWc9_rSpOKDw4kjbtqHMRPwBA"

private let fixtureSecretId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let fixtureRecipientKey = Data(repeating: 0x02, count: 32)
private let fixtureLabel = "cross-platform test vector"
private let fixtureSecretCreatedAt: Date = {
    let f = ISO8601DateFormatter()
    return f.date(from: "2026-01-01T00:00:00Z")!
}()
private let fixtureCiphertext = Data([1, 2, 3, 4, 5])
// k/n, then mimeType — each appended at the end of the field sequence in turn, so the fields
// above are byte-identical to the vector that predates them.
private let fixtureK = 2
private let fixtureN = 3
private let fixtureMimeType = MimeType("text/plain")

private func base64URLDecode(_ string: String) -> Data {
    var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let rem = s.count % 4
    if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
    return Data(base64Encoded: s)!
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Test func forOpenProducesTheFixedCanonicalBytes() {
    let canon = PayloadCanonical.forOpen(
        secretId: fixtureSecretId, transactionType: .deposit, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, ciphertext: fixtureCiphertext,
        k: fixtureK, n: fixtureN, mimeType: fixtureMimeType
    )
    let expected = "11111111-1111-1111-1111-111111111111\ndeposit\nAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI\ncross-platform test vector\n1767225600000\nAQIDBAU=\n2\n3\ntext/plain"
    #expect(String(data: canon, encoding: .utf8) == expected)
}

// NOTE: CryptoKit uses hedged (randomized) Ed25519 for fault-attack resistance — signature bytes
// differ from BouncyCastle's deterministic RFC 8032 output even for the same seed and message.
// Cross-library sign byte-identity therefore cannot be checked here. Instead: (a) the canonical
// bytes test above confirms field-order/encoding is identical on all platforms; (b) the
// verification test below confirms CryptoKit accepts a BouncyCastle-produced signature;
// (c) this test confirms CryptoKit's public key derivation matches and its own signatures verify.
@Test func signingWithTheFixedSeedDerivesTheExpectedPublicKeyAndProducesAVerifiableSignature() throws {
    let canon = PayloadCanonical.forOpen(
        secretId: fixtureSecretId, transactionType: .deposit, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, ciphertext: fixtureCiphertext,
        k: fixtureK, n: fixtureN, mimeType: fixtureMimeType
    )
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed)
    #expect(base64URLEncode(privateKey.publicKey.rawRepresentation) == expectedPublicKeyBase64Url)

    let signature = try privateKey.signature(for: canon)
    #expect(privateKey.publicKey.isValidSignature(signature, for: canon))
}

@Test func theFixedSignatureVerifiesAgainstTheFixedPublicKey() throws {
    let canon = PayloadCanonical.forOpen(
        secretId: fixtureSecretId, transactionType: .deposit, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, ciphertext: fixtureCiphertext,
        k: fixtureK, n: fixtureN, mimeType: fixtureMimeType
    )
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: base64URLDecode(expectedPublicKeyBase64Url))
    let signature = base64URLDecode(expectedSignatureBase64Url)
    #expect(publicKey.isValidSignature(signature, for: canon))
}

// ---------------------------------------------------------------------------
// forRotation — same cross-platform-interop purpose as forOpen above, using the
// same fixed private key seed. Identical fixture checked into
// deposplit.com/hexagons/relay/src/test/scala/value_objects/PayloadCanonicalVectorTests.scala
// and Android's PayloadCanonicalVectorTest.kt. Closes the gap this file's own comment used to
// flag: forRotation's vector was never added here when the rotation push shipped, and the
// appended newCipherSuite field made recomputing it unavoidable, so it is added properly now.
// ---------------------------------------------------------------------------

private let fixtureRotationRecipientKey = Data(repeating: 0x03, count: 32)
private let fixtureNewVerifyKey = Data(repeating: 0x04, count: 32)
private let fixtureNewEncKey = Data(repeating: 0x05, count: 32)
private let fixtureNewCipherSuite = CipherSuite.current
private let expectedRotationSignatureBase64Url = "EH45bL4chGQALZ6J9IDhfUAtPNovGHmqlJvF6HBKa8sqkF3SU1NhMGWmSTGM87isxdHIxoQCHFITplmzN1zeDg"

@Test func forRotationProducesTheFixedCanonicalBytes() {
    let canon = PayloadCanonical.forRotation(recipientKey: fixtureRotationRecipientKey, newVerifyKey: fixtureNewVerifyKey, newEncKey: fixtureNewEncKey, newCipherSuite: fixtureNewCipherSuite)
    let expected = "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM\nBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ\nBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU\ned25519+x25519-v1"
    #expect(String(data: canon, encoding: .utf8) == expected)
}

@Test func theFixedRotationSignatureVerifiesAgainstTheFixedPublicKey() throws {
    let canon = PayloadCanonical.forRotation(recipientKey: fixtureRotationRecipientKey, newVerifyKey: fixtureNewVerifyKey, newEncKey: fixtureNewEncKey, newCipherSuite: fixtureNewCipherSuite)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: base64URLDecode(expectedPublicKeyBase64Url))
    let signature = base64URLDecode(expectedRotationSignatureBase64Url)
    #expect(publicKey.isValidSignature(signature, for: canon))
}

// ---------------------------------------------------------------------------
// forHeartbeat — same cross-platform-interop purpose as forOpen above, using the same
// fixed private key seed. Identical fixture checked into
// deposplit.com/hexagons/relay/src/test/scala/value_objects/PayloadCanonicalVectorTests.scala.
// ---------------------------------------------------------------------------

private let fixtureHeartbeatOwnerKey = Data(repeating: 0x06, count: 32)
// Deliberately out of sorted order in the fixture to prove forHeartbeat sorts before joining — a
// naive pass-through would silently disagree with a platform that assembled the list differently.
private let fixtureHeartbeatSecretIds = [
    UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
    UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
]
private let expectedHeartbeatSignatureBase64Url = "w6fmGn4t7y2RSNakPBzi57H40u5kJI6CZAhEGdzLBOwZd__jabsge2tEmIpczMqEd3ODpNUJ72Ww2KEe8LYQCw"

@Test func forHeartbeatProducesTheFixedCanonicalBytesSortedRegardlessOfInputOrder() {
    let canon = PayloadCanonical.forHeartbeat(ownerKey: fixtureHeartbeatOwnerKey, secretIds: fixtureHeartbeatSecretIds, optedOut: false)
    let expected = "BgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgY\n11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222,33333333-3333-3333-3333-333333333333\nfalse"
    #expect(String(data: canon, encoding: .utf8) == expected)
}

@Test func theFixedHeartbeatSignatureVerifiesAgainstTheFixedPublicKey() throws {
    let canon = PayloadCanonical.forHeartbeat(ownerKey: fixtureHeartbeatOwnerKey, secretIds: fixtureHeartbeatSecretIds, optedOut: false)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: base64URLDecode(expectedPublicKeyBase64Url))
    let signature = base64URLDecode(expectedHeartbeatSignatureBase64Url)
    #expect(publicKey.isValidSignature(signature, for: canon))
}
