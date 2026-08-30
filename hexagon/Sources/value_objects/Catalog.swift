import Foundation

/// A self-managed export of the *non-secret* catalog — contact public keys, pseudonyms,
/// verification levels, and sender-side `ShareMetadata`/`Secret` records. Eases "who are my
/// holders" during identity recovery without weakening anything: none of this is a share or a
/// private key.
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
