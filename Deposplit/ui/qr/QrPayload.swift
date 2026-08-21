import hexagon
import Foundation

// `relay` carries the *displaying* device's currently-configured relay — the out-of-band exchange
// mechanism BYOR uses (deposplit.com/CLAUDE.md "BYOR"). nil means "use the scanning device's own
// default relay".
//
// `cipherSuite` (item 14 — "crypto agility") is the wire value of the signing + key-agreement
// algorithm pairing `verifyKey`/`encKey` use. Required, not optional/defaulted like `relay` —
// every exchange unambiguously has exactly one cipher suite in effect. Field names spelled out in
// full (not abbreviated to `ed`/`x`), matching the vocabulary used everywhere else in the codebase.
//
// `v` stays at 1 permanently — Deposplit is pre-launch and never supports decoding an old shape,
// so a version number never actually gates anything: a payload missing a newly-required field
// (like `cipherSuite` here) already fails to decode on its own, regardless of what `v` says.
// Bumping `v` on every field addition would be version-tracking ceremony with no compatibility
// matrix behind it to justify it.
struct QrPayload: Codable {
    let v: Int
    let pseudonym: String
    let verifyKey: String
    let encKey: String
    let relay: String?
    let cipherSuite: String

    static func encode(pseudonym: String, verifyKey: Data, encKey: Data, cipherSuite: CipherSuite, relayBaseUrl: String?) -> String? {
        let payload = QrPayload(v: 1, pseudonym: pseudonym,
                                verifyKey: verifyKey.base64URLEncoded,
                                encKey: encKey.base64URLEncoded,
                                relay: relayBaseUrl,
                                cipherSuite: cipherSuite.rawValue)
        return try? String(data: JSONEncoder().encode(payload), encoding: .utf8)
    }

    static func decode(_ json: String) -> QrPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QrPayload.self, from: data)
    }
}
