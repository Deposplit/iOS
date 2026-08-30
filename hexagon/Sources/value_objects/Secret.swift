import Foundation

/// Two-state lifecycle. No `discarded`
/// tombstone: once every holder confirms deletion (or the sender force-forgets), the `Secret`
/// record is removed outright.
public enum SecretState: String, Codable, Sendable, Equatable {
    case active, discarding
}

/// Sender-side per-secret aggregate — the single source of truth for `k`/`n`/`label`/
/// `secretCreatedAt`, keyed by `secretId`. `ShareMetadata` rows reference this rather than
/// duplicating its fields.
public struct Secret: Identifiable, Equatable, Hashable, Codable {
    public let id: UUID
    public let label: String
    public let k: Int
    public let n: Int
    public let secretCreatedAt: Date
    public let state: SecretState

    public init(id: UUID, label: String, k: Int, n: Int, secretCreatedAt: Date, state: SecretState) {
        self.id = id
        self.label = label
        self.k = k
        self.n = n
        self.secretCreatedAt = secretCreatedAt
        self.state = state
    }
}
