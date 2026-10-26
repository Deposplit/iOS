import Foundation

/// A signed custodial-heartbeat push addressed to this device — a holder's proactive
/// "still guarding {secretIds} for you" notice (or, when `optedOut` is true, a signed "my
/// silence from here on is not a loss signal" notice). Deliberately not a `ShareRequest`: no
/// singular `secretId`, no consent phase. Like `KeyRotation` it is consumed and deleted once read:
/// what it says is kept on this device, and the holder re-emits every interval.
///
/// `emittedAt` is the holder's own clock at signing, covered by the signature — the time custody
/// is dated from. The relay's receipt time is deliberately not carried: it is unsigned, and a
/// relay that could set it could keep a lost holder looking fresh. See
/// `PayloadCanonical.forHeartbeat` for the exact bytes signed.
public struct CustodyHeartbeat: Identifiable, Equatable {
    public let id: UUID
    public let holderKey: Data
    public let ownerKey: Data
    public let secretIds: [UUID]
    public let optedOut: Bool
    public let emittedAt: Date
    public let signature: Data

    public init(id: UUID, holderKey: Data, ownerKey: Data, secretIds: [UUID], optedOut: Bool, emittedAt: Date, signature: Data) {
        self.id = id
        self.holderKey = holderKey
        self.ownerKey = ownerKey
        self.secretIds = secretIds
        self.optedOut = optedOut
        self.emittedAt = emittedAt
        self.signature = signature
    }
}
