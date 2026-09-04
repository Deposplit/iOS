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
    /// When the identity this device holds today was established — set by `save()`, and deliberately
    /// left alone by `rotate()`. Rotation is continuous with what came before and propagates itself
    /// through signed notices every contact auto-accepts; registration is a break every contact has
    /// to be told about by hand. Nil on a device registered before this was recorded.
    var identityCreatedAt: Date? { get }
    /// This device's own public keys, or nil when they are gone or cannot be read. Optional rather
    /// than throwing, for the same reason as `previousDecKey()` below: absence is an ordinary state
    /// on a restored device, not an exception. Contrast `signKey()`/`decKey()`, where a caller who
    /// wants to sign has no fallback to fall back on.
    var verifyKey: Data? { get }
    var encKey: Data? { get }
    /// `signKey()` and `decKey()` must distinguish key material that is *absent or unusable* from
    /// key material that merely cannot be read at this moment — a locked device, a Keychain not yet
    /// available. The former is any error; the latter is specifically
    /// `AuthError.identityStorageUnavailable`. Only an adapter sees the platform's own error, so
    /// only an adapter can tell them apart, and `IdentityIntegrity` depends on the answer: it is
    /// what decides whether the app offers to mint a replacement identity over the top.
    func signKey() throws -> Data
    func decKey() throws -> Data
    /// The `decKey` displaced by the most recent `rotate`, or `nil` on an identity that has never
    /// rotated. Non-throwing: absence is the ordinary case, and a storage read that fails should
    /// cost the fallback, never the decryption that was going to succeed anyway.
    func previousDecKey() -> Data?
}
