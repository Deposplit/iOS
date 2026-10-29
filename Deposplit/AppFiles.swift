import hexagon
import Foundation

/// Where this app's local stores live, and the one place the backup decision is written on iOS.
///
/// Every file handed out here rides the device backup and a migration to a new iPhone. That is
/// deliberate, not the platform default winning by omission: the shares this phone holds for
/// other people have to survive a phone switch, because a restored device that has silently
/// forgotten them cannot tell anyone — it has no record it ever held anything, so the loss shows
/// up only as somebody else's redundancy quietly degrading. A single share is
/// information-theoretically independent of its secret, which is what makes carrying them safe.
///
/// The private keys are the exception and are not here at all: they live in the Keychain as
/// `ThisDeviceOnly` items, so they neither back up nor migrate.
///
/// Android says the same thing in `app/src/main/res/xml/data_extraction_rules.xml`; iOS has no
/// such file, which is why this type exists. The reasoning, and what a stolen backup would
/// yield, is in deposplit.com/docs/security.md under "Data at rest, and what a backup carries".
enum AppFiles {

    static func url(_ name: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(name)
    }

    /// How every store here writes a date and reads it back: ISO-8601 carrying exactly the
    /// millisecond `PayloadCanonical.epochMilliseconds` signs, which is what `wireInstant` builds.
    ///
    /// Not a default `ISO8601DateFormatter`, which drops the fraction: a date came back earlier
    /// than it went in, so an approval answered at .809 looked newer than the .000 saved for it, and
    /// was saved again on every launch. Nor `.withFractionalSeconds` alone, which rounds to the
    /// nearest millisecond where the signature truncates: half the time, a `secretCreatedAt` read
    /// back would sign one millisecond later than its deposit did.
    ///
    /// A date written without milliseconds does not parse. Deposplit is pre-launch, so stores are
    /// wiped rather than migrated.
    enum Dates {

        static func string(from date: Date) -> String {
            PayloadCanonical.wireInstant(date)
        }

        static func date(from string: String) -> Date? {
            parser.date(from: string)
        }

        private static let parser: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
    }
}
