import Foundation

/// The sender-declared media type of a secret — `"text/plain"` for everything that can be split
/// today.
///
/// Sender-supplied and best-effort, exactly the trust level `label` already has: nothing sniffs
/// the bytes to check the claim, and the relay could not check it if it wanted to, seeing only
/// ciphertext. It rides the deposit payload and the `inventory` push so a holder can hand it back
/// during recovery, and so reconstruction knows how to render what it produced.
///
/// A wrong or hostile value is a *rendering* risk, never a confidentiality one: by the time it is
/// read, `k` holders have already consented and the plaintext is already on this device.
public struct MimeType: Equatable, Hashable, Sendable, Codable {
    public static let `default` = MimeType("text/plain")

    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isText: Bool { essence.hasPrefix("text/") }
    public var isImage: Bool { essence.hasPrefix("image/") }

    /// Parameters dropped and lowercased, so `Text/Plain; charset=utf-8` classifies as text.
    /// Only classification normalises — `value` is what was signed and must stay byte-exact.
    private var essence: String {
        (value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Encoded as a bare string rather than a wrapper object, so a catalogue export reads the way
    /// `label` does.
    public init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
