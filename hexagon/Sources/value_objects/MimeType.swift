import Foundation

/// The sender-declared media type of a secret — `"text/plain"` for typed text, `"image/png"` or
/// `"image/jpeg"` for a picked image.
///
/// Best-effort in general, at exactly the trust level `label` already has: nothing on a receiving
/// device checks the claim against the bytes, and the relay could not check it either, seeing only
/// ciphertext. For a secret *this* device splits the claim is nevertheless true by construction,
/// because ``sniffed(_:)`` reads it off the payload rather than believing whatever handed the bytes
/// over. It rides the deposit payload and the `inventory` push so a holder can hand it back during
/// recovery, and so reconstruction knows how to render what it produced.
///
/// A wrong or hostile value is a *rendering* risk, never a confidentiality one: by the time it is
/// read, `k` holders have already consented and the plaintext is already on this device.
public struct MimeType: Equatable, Hashable, Sendable, Codable {
    public static let `default` = MimeType("text/plain")
    public static let png = MimeType("image/png")
    public static let jpeg = MimeType("image/jpeg")

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

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let jpegMagic: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// The image type these bytes actually are, or `nil` for anything else.
    ///
    /// The accepted set is PNG and JPEG deliberately, and is the whole of it: every additional
    /// format is more decoder surface reached by attacker-chosen bytes, for a use case nobody has
    /// asked for yet. SVG in particular is scriptable and will not be added.
    ///
    /// Recognition is by leading bytes, never by a file name, a UTType, or what a picker claimed,
    /// so the declared type of a secret this device splits cannot disagree with its payload.
    public static func sniffed(_ bytes: Data) -> MimeType? {
        if bytes.starts(with: pngMagic) { return .png }
        if bytes.starts(with: jpegMagic) { return .jpeg }
        return nil
    }
}
