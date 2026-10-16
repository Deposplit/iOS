import Foundation

/// Intra-hexagon interface — implemented by `IdentityService`, consumed by `ShareService`.
/// Lives in `services/` rather than `driving_ports` or `driven_ports` because both its
/// implementer and consumer are within the hexagon's service layer.
///
/// Every box is HPKE base mode under the current `TransportSuite`: a fresh ephemeral key per box,
/// discarded once it is sealed, so only the recipient can open it — not even the device that
/// sealed it. Wire format: suiteTag(1) || enc(32) || ciphertext+tag(16). The box proves nothing
/// about who sealed it; the Ed25519 signature covering it does, and is checked before every open.
public protocol ShareEncryption {
    /// Seals `plaintext` (a share, or a share being handed back) to `recipientEncKey`.
    func encrypt(_ plaintext: Data, recipientEncKey: Data) throws -> Data
    /// Opens a box sealed to this device, dispatching on the leading `TransportSuite` tag. Throws
    /// `TransportSuiteError.unsupported` for an unrecognized tag — never a silent misparse.
    func decrypt(_ data: Data) throws -> Data
    /// Seals a secret's label to `recipientEncKey` with the same box as `encrypt`, under HPKE info
    /// of its own, so a label box and a share box never share a key. The relay stores the result
    /// without being able to read it.
    func sealLabel(_ label: String, recipientEncKey: Data) throws -> Data
    /// Opens a label sealed to this device by `sealLabel`, with the same fallback to the previous
    /// `decKey` as `decrypt`.
    func openLabel(_ sealedLabel: Data) throws -> String
}
