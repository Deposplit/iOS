import Foundation

// `relay` carries the *displaying* device's currently-configured relay — the out-of-band exchange
// mechanism BYOR uses (deposplit.com/CLAUDE.md "BYOR"). nil means "use the scanning device's own
// default relay". Compatible both directions regardless of the `v` bump: a missing key for an
// Optional property decodes to nil, and old (v=1) readers ignore the extra field.
struct QrPayload: Codable {
    let v: Int
    let pseudonym: String
    let ed: String
    let x: String
    let relay: String?

    static func encode(pseudonym: String, edPublicKey: Data, xPublicKey: Data, relayBaseUrl: String?) -> String? {
        let payload = QrPayload(v: 2, pseudonym: pseudonym,
                                ed: edPublicKey.base64URLEncoded,
                                x: xPublicKey.base64URLEncoded,
                                relay: relayBaseUrl)
        return try? String(data: JSONEncoder().encode(payload), encoding: .utf8)
    }

    static func decode(_ json: String) -> QrPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QrPayload.self, from: data)
    }
}
