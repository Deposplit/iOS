import Testing
@testable import hexagon
import Foundation

// The vector tests beside this one pin the canonical bytes for a fixed instant, which is what
// keeps the four implementations agreeing on field order and encoding. They cannot catch the
// other half of the contract: the relay never verifies against the bytes the sender built, it
// rebuilds them from the ISO-8601 timestamp it parsed off the wire. So the wire form has to carry
// the same milliseconds the signature covers — and the fixed instant every vector uses sits on a
// whole second, where that distinction is invisible.
//
// It was not invisible in the app. `ShareService.deposit` stamps `Date()`, which is never on a
// whole second, and the adapter formatted it with a default `ISO8601DateFormatter`, which drops
// fractional seconds. Every share request iOS opened was therefore signed at one millisecond and
// sent at another, and the relay rejected all of them with a bare 400.

private func relayView(of wire: String) throws -> Date {
    // Instant.parse on the relay's side, which keeps whatever fraction it is given — and, being
    // the only reader of this field, is under no obligation to accept one that omits it.
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try #require(parser.date(from: wire))
}

@Test func theWireInstantSpellsOutTheMillisecondsTheSignatureCovers() {
    #expect(PayloadCanonical.wireInstant(Date(timeIntervalSince1970: 1767225600)) == "2026-01-01T00:00:00.000Z")
    #expect(PayloadCanonical.wireInstant(Date(timeIntervalSince1970: 1767225600.123)) == "2026-01-01T00:00:00.123Z")
    // Zero-padded rather than "…00.5Z", which would parse to 500ms and not to the 5 signed here.
    #expect(PayloadCanonical.wireInstant(Date(timeIntervalSince1970: 1767225600.005)) == "2026-01-01T00:00:00.005Z")
}

@Test func aDepositStampedNowSurvivesTheRoundTripTheRelayPerformsOnIt() throws {
    for _ in 0..<200 {
        let createdAt = Date()
        let asSigned = PayloadCanonical.forOpen(
            secretId: UUID(), transactionType: .deposit, recipientKey: Data(repeating: 0x02, count: 32),
            label: "round trip", secretCreatedAt: createdAt, ciphertext: Data([1, 2, 3]),
            k: 2, n: 2, mimeType: MimeType("text/plain")
        )
        let asTheRelayRebuildsIt = PayloadCanonical.forOpen(
            secretId: UUID(), transactionType: .deposit, recipientKey: Data(repeating: 0x02, count: 32),
            label: "round trip", secretCreatedAt: try relayView(of: PayloadCanonical.wireInstant(createdAt)),
            ciphertext: Data([1, 2, 3]), k: 2, n: 2, mimeType: MimeType("text/plain")
        )
        // Only the secretId differs, and only on its own line — everything after the timestamp,
        // the timestamp included, has to match or the senderSignature does not verify.
        #expect(asSigned.dropFirst(36) == asTheRelayRebuildsIt.dropFirst(36))
    }
}
