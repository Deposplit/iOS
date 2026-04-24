import Foundation

struct QrPayload: Codable {
    let v: Int
    let pseudonym: String
    let ed: String
    let x: String

    static func encode(pseudonym: String, edPublicKey: Data, xPublicKey: Data) -> String? {
        let payload = QrPayload(v: 1, pseudonym: pseudonym,
                                ed: edPublicKey.base64URLEncoded,
                                x: xPublicKey.base64URLEncoded)
        return try? String(data: JSONEncoder().encode(payload), encoding: .utf8)
    }

    static func decode(_ json: String) -> QrPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(QrPayload.self, from: data)
    }
}
