import Foundation

/// The deposit-retention rule — the sender retains each per-holder encrypted blob locally
/// until that holder's pickup is confirmed (relay-observed or heartbeat-attested), then discards
/// it. Retained so a relay GC before pickup can be answered with a cheap re-deposit rather than
/// counted as a lost share: each blob is encrypted to the *holder's* X25519 key, so the sender
/// cannot decrypt it herself — retaining all `n` is `n` opaque forward-only blobs, not a
/// reconstructable secret sitting on her device.
///
/// The re-deposit itself is **not implemented**: nothing reads `ciphertext` back. That path lands
/// with relay-side collection, which does not exist either, so the gap costs nothing today —
/// until then this record serves only as the "not yet confirmed by any channel" marker
/// `syncDistributed` gates on. `id` matches the originating deposit `ShareRequest`'s id (and
/// therefore `ShareMetadata.id`), so the record can be looked up and discarded by the same key
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
