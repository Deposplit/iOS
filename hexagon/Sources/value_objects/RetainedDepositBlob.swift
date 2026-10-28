import Foundation

/// The sender's record that a holder's pickup is not yet confirmed. Kept from the deposit until
/// the pickup is confirmed (relay-observed or heartbeat-attested), the holder withdraws, or the
/// holder's `ShareMetadata` goes with an approved removal or a Force Forget — then discarded.
/// Each blob is sealed to the *holder's* X25519 key under an ephemeral key discarded at sealing,
/// so the sender cannot open it herself — retaining all `n` is `n` opaque forward-only blobs, not
/// a reconstructable secret sitting on her device.
///
/// Nothing reads `ciphertext` back, and nothing re-deposits from it: the relay expires a deposit
/// nobody picks up, like any row, and a holder who never picked up never counted toward `n_live`.
/// So the record serves only as the "not yet confirmed by any channel" marker `syncDistributed`
/// gates on. `id` matches the originating deposit `ShareRequest`'s id (and therefore
/// `ShareMetadata.id`), so the record can be looked up and discarded by the same key
/// `syncDistributed` already keys off of.
public struct RetainedDepositBlob: Identifiable, Equatable {
    public let id: UUID
    public let secretId: UUID
    public let contactId: UUID
    public let label: String
    public let secretCreatedAt: Date
    public let ciphertext: Data
    public let k: Int
    public let n: Int
    public let mimeType: MimeType

    public init(id: UUID, secretId: UUID, contactId: UUID, label: String, secretCreatedAt: Date, ciphertext: Data, k: Int, n: Int, mimeType: MimeType) {
        self.id = id
        self.secretId = secretId
        self.contactId = contactId
        self.label = label
        self.secretCreatedAt = secretCreatedAt
        self.ciphertext = ciphertext
        self.k = k
        self.n = n
        self.mimeType = mimeType
    }
}
