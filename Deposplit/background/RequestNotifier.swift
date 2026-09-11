import Foundation
import UserNotifications

/// The one thing a background pass is allowed to interrupt somebody for.
///
/// A pending retrieval is a contact who cannot go any further until this phone answers, and who
/// has no other way to say so — the relay is blind and may not hold a push token beside a public
/// key, so the alternative to this is that they wait until somebody happens to open the app. The
/// notice is produced here, on this device, from rows it has already fetched under its own
/// identity: nothing about it reaches a third party and nothing new is asked of the relay.
///
/// Removals deliberately say nothing. The sender flipped her secret to destroying the moment she
/// asked and is not waiting on the answer to carry on, so learning of it at the next launch costs
/// nobody anything — and a lock screen that speaks twice as often for one real interruption is
/// worse at the job.
///
/// What it says names nobody and no secret, and does not count them. Somebody glancing at a locked
/// phone learns only that Deposplit is installed, which the home screen already told them.
enum RequestNotifier {

    /// One fixed identifier, so a second pass replaces the standing notice rather than stacking
    /// another copy of the same sentence behind it.
    private static let notificationIdentifier = "retrieval-waiting"

    private static let announcedKey = "announcedRetrievalRequests"
    private static let explanationShownKey = "notificationExplanationShown"

    /// Posts once per request, however many passes see it.
    ///
    /// The ids are the retrieval half of `listPendingRequests`, whose signatures the domain has
    /// already checked, so a forged row cannot raise a notification.
    static func announce(requestIds: [UUID]) async {
        let defaults = UserDefaults.standard
        let stillPending = Set(requestIds.map(\.uuidString))
        let announced = Set(defaults.stringArray(forKey: announcedKey) ?? [])

        guard await canNotify() else {
            // Record nothing that was never shown: authorisation may arrive later, and the request
            // will still be waiting when it does. Pruning still happens, so a phone that never
            // gets it does not accumulate ids for ever.
            defaults.set(Array(announced.intersection(stillPending)), forKey: announcedKey)
            return
        }

        let unannounced = stillPending.subtracting(announced)
        // Pruned to what is still pending, so answering a request lets its id go — and a re-issued
        // ask is a fresh row with a fresh id, which announces itself again.
        defaults.set(Array(stillPending), forKey: announcedKey)
        guard !unannounced.isEmpty else { return }

        let content = UNMutableNotificationContent()
        // Body and no title. iOS already writes the app's name above it, so a title would be a
        // second line for one sentence to fill.
        content.body = String(
            localized: "One of your contacts wants to reconstruct a secret with a share that you are keeping safe."
        )
        content.sound = .default
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Raises the system prompt, which appears exactly once in an app's life — hence the
    /// explanation that precedes it.
    ///
    /// No badge is asked for: a count of anything is a count this notice may not give.
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Whether the explanation has already been put to this device, so it is offered once rather
    /// than every time a share lands.
    static var explanationShown: Bool {
        UserDefaults.standard.bool(forKey: explanationShownKey)
    }

    static func markExplanationShown() {
        UserDefaults.standard.set(true, forKey: explanationShownKey)
    }

    private static func canNotify() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}
