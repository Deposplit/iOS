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
    /// `k`/`n` (item 8) are appended at the end of the sequence, keeping the existing field
    /// order — and this construction's cross-platform byte-vector test — undisturbed.
    public static func forOpen(
        secretId: UUID,
        transactionType: ShareTransactionType,
        recipientKey: Data,
        label: String,
        secretCreatedAt: Date,
        shareId: UUID?,
        ciphertext: Data?,
        k: Int? = nil,
        n: Int? = nil
    ) -> Data {
        let epochMs = Int64(secretCreatedAt.timeIntervalSince1970 * 1000)
        let parts = [
            secretId.uuidString.lowercased(),
            wire(transactionType),
            recipientKey.base64URLEncodedForSigning,
            label,
            String(epochMs),
            shareId?.uuidString.lowercased() ?? "",
            ciphertext?.base64EncodedString() ?? "",
            k.map(String.init) ?? "",
            n.map(String.init) ?? "",
        ]
        return Data(parts.joined(separator: "\n").utf8)
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

    /// Signed by the old key when pushing a rotation notice (item 9), i.e. by the caller who
    /// becomes `KeyRotation.oldVerifyKey`. Proves continuity of key control — only someone
    /// holding the old private key can produce this signature, which is what lets the recipient
    /// auto-verify and auto-accept the rotation without a fresh human re-verification.
    ///
    /// `newCipherSuite` (item 14) is appended at the end of the sequence, keeping the pre-item-14
    /// field order — and this construction's cross-platform byte-vector test — undisturbed. No
    /// `oldCipherSuite` is signed — the recipient already has it pinned on the existing contact
    /// record.
    public static func forRotation(recipientKey: Data, newVerifyKey: Data, newEncKey: Data, newCipherSuite: CipherSuite) -> Data {
        let parts = [
            recipientKey.base64URLEncodedForSigning,
            newVerifyKey.base64URLEncodedForSigning,
            newEncKey.base64URLEncodedForSigning,
            newCipherSuite.rawValue,
        ]
        return Data(parts.joined(separator: "\n").utf8)
    }

    /// Signed by the holder when pushing a custodial-heartbeat push (item 12), i.e. by the caller
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
