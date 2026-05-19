import Foundation

public enum VerificationLevel: String, Codable {
    case unverified, verified
}

public struct Contact: Identifiable, Equatable {
    public let id: UUID
    public let pseudonym: String
    public let edPublicKey: Data
    public let xPublicKey: Data
    public let verificationLevel: VerificationLevel
    public let verifiedAt: Date?
    public let addedAt: Date

    public init(
        id: UUID, pseudonym: String,
        edPublicKey: Data, xPublicKey: Data,
        verificationLevel: VerificationLevel, verifiedAt: Date?, addedAt: Date
    ) {
        self.id = id
        self.pseudonym = pseudonym
        self.edPublicKey = edPublicKey
        self.xPublicKey = xPublicKey
        self.verificationLevel = verificationLevel
        self.verifiedAt = verifiedAt
        self.addedAt = addedAt
    }
}
