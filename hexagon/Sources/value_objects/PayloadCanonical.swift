import Foundation

/// Canonical byte constructions for the two payload-level signatures that ride with a
/// ShareRequest row (`senderSignature`, `recipientSignature`), independent of the per-call
/// transport-auth signature. Mirrors deposplit.com's `hexagons/relay` PayloadCanonical
/// byte-for-byte — keep both in sync.
///
/// The transport signature authenticates the HTTP caller for one specific call and is never
/// persisted, so it gives a later reader of a row nothing to re-verify authorship against. These
/// two signatures close that gap, which is what makes BYOR (a relay other than deposplit.com)
/// safe: any holder of the author's Ed25519 public key can independently re-verify who authored a
/// row, regardless of which relay served it.
///
/// `secretCreatedAt` is signed as epoch milliseconds (not the ISO-8601 wire string) and UUIDs are
/// signed lowercase — both choices exist purely to keep the signed bytes byte-identical across
/// the JVM, Kotlin, and Swift implementations. `UUID.uuidString` is uppercase by default in
/// Swift (unlike `java.util.UUID.toString()`), so every UUID component here is explicitly
/// lowercased — forgetting this would silently break cross-platform signature verification.
public enum PayloadCanonical {

    private static func wire(_ type: ShareTransactionType) -> String { type.rawValue }

    /// Signed by the sender when opening a share request (`senderSignature`).
    ///
    /// `k`/`n`, then `mimeType`, are each appended at the end of the sequence in turn, keeping the
    /// field order that predates them — and this construction's cross-platform byte-vector test —
    /// undisturbed.
    ///
    /// A nil and an empty-string `mimeType` produce identical bytes here, which is why the relay
    /// refuses to store an empty one.
    public static func forOpen(
        secretId: UUID,
        transactionType: ShareTransactionType,
        recipientKey: Data,
        label: String,
        secretCreatedAt: Date,
        ciphertext: Data?,
        k: Int? = nil,
        n: Int? = nil,
        mimeType: MimeType? = nil
    ) -> Data {
        let epochMs = epochMilliseconds(secretCreatedAt)
        let parts = [
            secretId.uuidString.lowercased(),
            wire(transactionType),
            recipientKey.base64URLEncodedForSigning,
            label,
            String(epochMs),
            ciphertext?.base64EncodedString() ?? "",
            k.map(String.init) ?? "",
            n.map(String.init) ?? "",
            mimeType?.value ?? "",
        ]
        return Data(parts.joined(separator: "\n").utf8)
    }

    /// The epoch-millisecond value `forOpen` signs for a `secretCreatedAt`.
    ///
    /// Public because the ISO-8601 string that travels beside the signature has to carry exactly
    /// these milliseconds. The relay does not take the signature on trust against the bytes we
    /// built: it rebuilds them from the timestamp it parsed off the wire, so a wire form that
    /// carries a different millisecond than the one signed here fails to verify — every time,
    /// not occasionally.
    public static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// A `secretCreatedAt` in the form the relay parses, carrying exactly the milliseconds
    /// `epochMilliseconds` signs.
    ///
    /// Built from that integer rather than by formatting the `Date` again, so no rounding of its
    /// own can put a different millisecond on the wire than in the signature. Foundation's
    /// default `ISO8601DateFormatter` omits fractional seconds altogether, which is the trap this
    /// exists to close: `Date()` is never on a whole second, so every share request iOS opened
    /// was signed at one millisecond and transmitted at another, and the relay rejected all of
    /// them. Kotlin and Scala reach the same place for free — `Instant.toString` keeps the
    /// fraction and `Instant.parse` gives it back.
    public static func wireInstant(_ date: Date) -> String {
        let epochMs = epochMilliseconds(date)
        // Floored, not truncated toward zero, so a pre-1970 instant still lands on a whole second
        // with a millisecond remainder in 0..<1000 rather than a negative one.
        let seconds = epochMs >= 0 ? epochMs / 1000 : (epochMs - 999) / 1000
        let milliseconds = String(epochMs - seconds * 1000)
        let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return whole.dropLast() + "." + String(repeating: "0", count: 3 - milliseconds.count) + milliseconds + "Z"
    }

    /// Signed by the recipient when responding to a share request (`recipientSignature`).
    public static func forRespond(requestId: UUID, approved: Bool, ciphertext: Data?) -> Data {
        let parts = [
            requestId.uuidString.lowercased(),
            approved ? "approved" : "denied",
            ciphertext?.base64EncodedString() ?? "",
        ]
        return Data(parts.joined(separator: "\n").utf8)
    }

    /// Signed by the old key when pushing a rotation notice, i.e. by the caller who
    /// becomes `KeyRotation.oldVerifyKey`. Proves continuity of key control — only someone
    /// holding the old private key can produce this signature, which is what lets the recipient
    /// auto-verify and auto-accept the rotation without a fresh human re-verification.
    ///
    /// `newCipherSuite` is appended at the end of the sequence, keeping the field order that
    /// predates cipher suites — and this construction's cross-platform byte-vector test —
    /// undisturbed. No `oldCipherSuite` is signed — the recipient already has it pinned on the
    /// existing contact record.
    public static func forRotation(recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite) -> Data {
        let parts = [
            recipientKey.base64URLEncodedForSigning,
            newVerifyKey.base64URLEncodedForSigning,
            newEncKey.base64URLEncodedForSigning,
            newCipherSuite.rawValue,
        ]
        return Data(parts.joined(separator: "\n").utf8)
    }

    /// Signed by the holder when pushing a custodial-heartbeat push, i.e. by the caller
    /// who becomes `CustodyHeartbeat.holderKey`. `secretIds` is sorted (lowercase UUID string)
    /// before joining so the signed bytes are independent of list-construction order on either
    /// side. The same construction covers the opt-out notice (`optedOut = true`, `secretIds`
    /// typically empty) — mechanically the same signed row, just a different meaning to the reader.
    public static func forHeartbeat(ownerKey: Data, secretIds: [UUID], optedOut: Bool) -> Data {
        let parts = [
            ownerKey.base64URLEncodedForSigning,
            secretIds.map { $0.uuidString.lowercased() }.sorted().joined(separator: ","),
            optedOut ? "true" : "false",
        ]
        return Data(parts.joined(separator: "\n").utf8)
    }
}

/// Local, hexagon-scoped base64url encoding — the app-layer `Data.base64URLEncoded` extension
/// (in `Deposplit/api/DeposplitApiAdapter.swift`) lives in a different Swift module and isn't
/// visible here.
private extension Data {
    var base64URLEncodedForSigning: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
