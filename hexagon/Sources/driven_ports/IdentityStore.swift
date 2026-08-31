import Foundation

public protocol IdentityStore {
    var isRegistered: Bool { get }
    /// Registration. Establishes a brand-new identity, so any retained previous `decKey` is
    /// cleared — it belonged to an identity this device is no longer continuous with.
    func save(pseudonym: String, verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws
    /// Rotation. Persists the new keys and moves the displaced `decKey` into the previous slot,
    /// preserving the pseudonym. Separate from `save` because only rotation is continuous with
    /// what came before, and only rotation may leave an old key readable.
    ///
    /// Only the `decKey` is kept. The old `signKey` is destroyed here: retaining it would let
    /// someone who extracts an unlocked device sign a rotation notice as the *previous* identity,
    /// which every contact would auto-accept as proof of key continuity.
    func rotate(verifyKey: Data, signKey: Data, encKey: Data, decKey: Data) throws
    var pseudonym: String { get }
    var verifyKey: Data { get }
    var encKey: Data { get }
    func signKey() throws -> Data
    func decKey() throws -> Data
    /// The `decKey` displaced by the most recent `rotate`, or `nil` on an identity that has never
    /// rotated. Non-throwing: absence is the ordinary case, and a storage read that fails should
    /// cost the fallback, never the decryption that was going to succeed anyway.
    func previousDecKey() -> Data?
}
