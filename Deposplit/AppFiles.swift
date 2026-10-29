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
}
