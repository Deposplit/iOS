import Foundation

/// The catalogue file: version 1 of the format both apps read and write, specified under "The
/// catalogue export" in deposplit.com/docs/security.md. It is what lets a catalogue exported on an
/// iPhone be imported on Android and back, the one switch a device backup cannot carry.
///
/// Spelled out field by field rather than left to synthesised `Codable`, because the file is a
/// commitment across platforms and across time: renaming or adding a property must not quietly
/// change what an export contains. Android's `CatalogCodec` is the same format, and the two test
/// suites decode one shared fixture to keep them that way.
///
/// It lives in the hexagon, where Android's lives in the app, because this is where Swift Testing
/// can reach it: the app target has no tests.
enum CatalogCodec {

    static let version = 1

    static func encode(_ catalog: Catalog) throws -> Data {
        let wire = CatalogWire(
            version: version,
            contacts: catalog.contacts.map(ContactWire.init),
            secrets: catalog.secrets.map(SecretWire.init),
            shareMetadata: catalog.shareMetadata.map(ShareMetadataWire.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    static func decode(_ data: Data) throws -> Catalog {
        let wire = try JSONDecoder().decode(CatalogWire.self, from: data)
        guard wire.version == version else { throw CatalogCodecError.unsupportedVersion(wire.version) }
        return Catalog(
            contacts: try wire.contacts.map { try $0.toDomain() },
            secrets: try wire.secrets.map { try $0.toDomain() },
            shareMetadata: try wire.shareMetadata.map { try $0.toDomain() }
        )
    }
}

public enum CatalogCodecError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformed(field: String, value: String)
}

private struct CatalogWire: Codable {
    let version: Int
    let contacts: [ContactWire]
    let secrets: [SecretWire]
    let shareMetadata: [ShareMetadataWire]
}

private struct ContactWire: Codable {
    let id: String
    let pseudonym: String
    let verifyKey: String
    let encKey: String
    let verificationLevel: String
    let verifiedAt: String?
    let addedAt: String
    let relayBaseUrl: String?
    let cipherSuite: String
    let nickname: String?
    // Optional on reading, because a field still at its default may be left out — Android leaves
    // out every one that is. Always written.
    let revokedVerifyKeys: [String]?
    let keyChangedAt: String?
    let heartbeatOptedOutAt: String?
    let lastHeartbeatSentAt: String?
    let heartbeatEmissionOptedOut: Bool?

    init(_ contact: Contact) {
        id = contact.id.uuidString.lowercased()
        pseudonym = contact.pseudonym
        verifyKey = contact.verifyKey.catalogBase64URL
        encKey = contact.encKey.catalogBase64URL
        verificationLevel = contact.verificationLevel.rawValue
        verifiedAt = contact.verifiedAt.map(PayloadCanonical.wireInstant)
        addedAt = PayloadCanonical.wireInstant(contact.addedAt)
        relayBaseUrl = contact.relayBaseUrl
        cipherSuite = contact.cipherSuite.rawValue
        nickname = contact.nickname
        revokedVerifyKeys = contact.revokedVerifyKeys.map(\.catalogBase64URL)
        keyChangedAt = contact.keyChangedAt.map(PayloadCanonical.wireInstant)
        heartbeatOptedOutAt = contact.heartbeatOptedOutAt.map(PayloadCanonical.wireInstant)
        lastHeartbeatSentAt = contact.lastHeartbeatSentAt.map(PayloadCanonical.wireInstant)
        heartbeatEmissionOptedOut = contact.heartbeatEmissionOptedOut
    }

    func toDomain() throws -> Contact {
        Contact(
            id: try uuid(id, "contacts.id"),
            pseudonym: pseudonym,
            verifyKey: try key(verifyKey, "contacts.verifyKey"),
            encKey: try key(encKey, "contacts.encKey"),
            verificationLevel: try value(verificationLevel, "contacts.verificationLevel"),
            verifiedAt: try verifiedAt.map { try date($0, "contacts.verifiedAt") },
            addedAt: try date(addedAt, "contacts.addedAt"),
            relayBaseUrl: relayBaseUrl,
            revokedVerifyKeys: try (revokedVerifyKeys ?? []).map { try key($0, "contacts.revokedVerifyKeys") },
            keyChangedAt: try keyChangedAt.map { try date($0, "contacts.keyChangedAt") },
            heartbeatOptedOutAt: try heartbeatOptedOutAt.map { try date($0, "contacts.heartbeatOptedOutAt") },
            lastHeartbeatSentAt: try lastHeartbeatSentAt.map { try date($0, "contacts.lastHeartbeatSentAt") },
            heartbeatEmissionOptedOut: heartbeatEmissionOptedOut ?? false,
            cipherSuite: try value(cipherSuite, "contacts.cipherSuite"),
            nickname: nickname
        )
    }
}

private struct SecretWire: Codable {
    let id: String
    let label: String
    let k: Int
    let n: Int
    let mimeType: String
    let secretCreatedAt: String
    let state: String

    init(_ secret: Secret) {
        id = secret.id.uuidString.lowercased()
        label = secret.label
        k = secret.k
        n = secret.n
        mimeType = secret.mimeType.value
        secretCreatedAt = PayloadCanonical.wireInstant(secret.secretCreatedAt)
        state = secret.state.rawValue
    }

    func toDomain() throws -> Secret {
        Secret(
            id: try uuid(id, "secrets.id"),
            label: label,
            mimeType: MimeType(mimeType),
            k: k,
            n: n,
            secretCreatedAt: try date(secretCreatedAt, "secrets.secretCreatedAt"),
            state: try value(state, "secrets.state")
        )
    }
}

private struct ShareMetadataWire: Codable {
    let id: String
    let secretId: String
    let contactId: String
    let lastConfirmedAt: String?

    init(_ meta: ShareMetadata) {
        id = meta.id.uuidString.lowercased()
        secretId = meta.secretId.uuidString.lowercased()
        contactId = meta.contactId.uuidString.lowercased()
        lastConfirmedAt = meta.lastConfirmedAt.map(PayloadCanonical.wireInstant)
    }

    func toDomain() throws -> ShareMetadata {
        ShareMetadata(
            id: try uuid(id, "shareMetadata.id"),
            secretId: try uuid(secretId, "shareMetadata.secretId"),
            contactId: try uuid(contactId, "shareMetadata.contactId"),
            lastConfirmedAt: try lastConfirmedAt.map { try date($0, "shareMetadata.lastConfirmedAt") }
        )
    }
}

/// Written with `PayloadCanonical.wireInstant`, read here with any number of fractional digits.
private func date(_ string: String, _ field: String) throws -> Date {
    guard let date = PayloadCanonical.parseWireInstant(string) else { throw CatalogCodecError.malformed(field: field, value: string) }
    return date
}

private func uuid(_ string: String, _ field: String) throws -> UUID {
    guard let uuid = UUID(uuidString: string) else { throw CatalogCodecError.malformed(field: field, value: string) }
    return uuid
}

private func key(_ string: String, _ field: String) throws -> Data {
    guard let key = Data(catalogBase64URL: string) else { throw CatalogCodecError.malformed(field: field, value: string) }
    return key
}

private func value<T: RawRepresentable>(_ string: String, _ field: String) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: string) else { throw CatalogCodecError.malformed(field: field, value: string) }
    return value
}

/// The catalogue's base64url, unpadded. Its own pair because the app's `Data.base64URLEncoded` is
/// in another module and `PayloadCanonical`'s is private to the signed bytes.
private extension Data {
    var catalogBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(catalogBase64URL string: String) {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: standard)
    }
}
