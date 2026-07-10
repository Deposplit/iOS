import Testing
@testable import hexagon
import Foundation
import CryptoKit

// Cross-platform interop vector for PayloadCanonical.forOpen's byte construction — mirrors the
// existing hand-derived SSS test vectors (ShamirTest.kt / ShamirSecretSharingTests.swift, see
// deposplit.com/CLAUDE.md "Cross-Platform Compatibility"). Ed25519 sign/verify interop across
// BouncyCastle/CryptoKit is already proven via the transport-auth signature; what this vector
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
private let expectedSignatureBase64Url = "_EvKOl019mJekfMc34HdAkiEULJGph_zAz-yqwqgX25_JlBkTweeqOeSJJKf2tEb0peCZez_3YKY-DHdHF7NAw"

private let fixtureSecretId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let fixtureRecipientKey = Data(repeating: 0x02, count: 32)
private let fixtureLabel = "cross-platform test vector"
private let fixtureSecretCreatedAt: Date = {
    let f = ISO8601DateFormatter()
    return f.date(from: "2026-01-01T00:00:00Z")!
}()
private let fixtureCiphertext = Data([1, 2, 3, 4, 5])

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
        secretId: fixtureSecretId, requestType: .pickUp, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, shareId: nil, ciphertext: fixtureCiphertext
    )
    let expected = "11111111-1111-1111-1111-111111111111\npick_up\nAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI\ncross-platform test vector\n1767225600000\n\nAQIDBAU="
    #expect(String(data: canon, encoding: .utf8) == expected)
}

@Test func signingTheCanonicalBytesWithTheFixedSeedReproducesTheFixedSignature() throws {
    let canon = PayloadCanonical.forOpen(
        secretId: fixtureSecretId, requestType: .pickUp, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, shareId: nil, ciphertext: fixtureCiphertext
    )
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed)
    #expect(base64URLEncode(privateKey.publicKey.rawRepresentation) == expectedPublicKeyBase64Url)

    let signature = try privateKey.signature(for: canon)
    #expect(base64URLEncode(signature) == expectedSignatureBase64Url)
}

@Test func theFixedSignatureVerifiesAgainstTheFixedPublicKey() throws {
    let canon = PayloadCanonical.forOpen(
        secretId: fixtureSecretId, requestType: .pickUp, recipientKey: fixtureRecipientKey,
        label: fixtureLabel, secretCreatedAt: fixtureSecretCreatedAt, shareId: nil, ciphertext: fixtureCiphertext
    )
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: base64URLDecode(expectedPublicKeyBase64Url))
    let signature = base64URLDecode(expectedSignatureBase64Url)
    #expect(publicKey.isValidSignature(signature, for: canon))
}
