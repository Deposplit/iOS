import Foundation

enum VerificationLevel: String, Codable {
    case unverified, verified
}

struct Contact: Identifiable, Equatable {
    let id: UUID
    let pseudonym: String
    let edPublicKey: Data
    let xPublicKey: Data
    let verificationLevel: VerificationLevel
    let verifiedAt: Date?
    let addedAt: Date
}
