import Foundation

/// A self-managed export of the *non-secret* catalog — contact public keys, pseudonyms,
/// verification levels, and sender-side `ShareMetadata`/`Secret` records. Eases "who are my
/// holders" during identity recovery (item 8) without weakening anything: none of this is a
/// share or a private key. See deposplit.com/CLAUDE.md "What is next" item 8, "Optional catalog
/// backup".
public struct Catalog: Codable, Equatable {
    public let contacts: [Contact]
    public let secrets: [Secret]
    public let shareMetadata: [ShareMetadata]

    public init(contacts: [Contact], secrets: [Secret], shareMetadata: [ShareMetadata]) {
        self.contacts = contacts
        self.secrets = secrets
        self.shareMetadata = shareMetadata
    }
}
