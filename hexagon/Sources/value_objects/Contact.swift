import Foundation

public enum VerificationLevel: String, Codable, Sendable {
    case unverified, verified
}

public struct Contact: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pseudonym: String
    public let edPublicKey: Data
    public let xPublicKey: Data
    public let verificationLevel: VerificationLevel
    public let verifiedAt: Date?
    public let addedAt: Date
    /// BYOR override — nil means "use the device's configured default relay". A pinned snapshot
    /// at contact-add time, not a live pointer, same TOFU trust model as the public keys.
    public let relayBaseUrl: String?

    public init(
        id: UUID, pseudonym: String,
        edPublicKey: Data, xPublicKey: Data,
        verificationLevel: VerificationLevel, verifiedAt: Date?, addedAt: Date,
        relayBaseUrl: String? = nil
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.edPublicKey = edPublicKey
        self.xPublicKey = xPublicKey
        self.verificationLevel = verificationLevel
        self.verifiedAt = verifiedAt
        self.addedAt = addedAt
        self.relayBaseUrl = relayBaseUrl
    }
}
