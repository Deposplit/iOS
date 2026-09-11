import BackgroundTasks
import Foundation
import hexagon

/// The daily holder-side pass, so that keeping a share safe does not depend on somebody opening
/// the app.
///
/// Every custody signal an owner reads is emitted from the holder's inbox poll, and that poll only
/// ran while somebody had Deposplit open. A holder who simply does not launch it for nine days
/// therefore drops out of that owner's `n_live` for every secret they hold, for reasons that have
/// nothing to do with custody — and a retrieval waiting on them goes unseen for just as long.
///
/// Roughly daily against a three-day emission interval puts a heartbeat that has come due on the
/// wire within a day of doing so, comfortably inside the nine-day loss threshold. The system picks
/// the moment, which does a second job: the relay learns that this phone was awake sometime today
/// rather than getting a punctual tick it could fingerprint a device by. That is a scheduling
/// choice doing privacy work rather than a privacy mechanism — the source address is a larger
/// identifier than the timing ever was.
///
/// `@MainActor` is load-bearing rather than decorative. `.backgroundTask` hands its work to a
/// `@Sendable` closure, while the hexagon declares no default isolation, so `ShareService` is
/// neither isolated nor `Sendable`. A class isolated to a global actor *is* `Sendable`, so this is
/// what may cross into that closure — and everything it touches is then back on the main actor.
///
/// One thing the platform cannot be argued out of: app-refresh budget follows app usage, so the
/// holder who never opens Deposplit — precisely the holder this exists for — gets the fewest
/// passes. `BGProcessingTask` is not the way round it: that runs during nightly maintenance while
/// the phone is charging and therefore locked, which the guard below turns into a no-op anyway.
@MainActor
final class CustodyRefresh {

    /// Also listed in `BGTaskSchedulerPermittedIdentifiers` in the repository-root `Info.plist`.
    /// The two must agree or the scheduler refuses every request, silently.
    static let taskIdentifier = "com.deposplit.custody-refresh"

    private let auth: any Identity
    private let shareManagement: any ShareManagement

    init(auth: any Identity, shareManagement: any ShareManagement) {
        self.auth = auth
        self.shareManagement = shareManagement
    }

    /// Asks for the next pass. Safe to call as often as it likes: a second request under the same
    /// identifier replaces the pending one rather than stacking beside it.
    ///
    /// A phone with no identity has nothing to emit and nothing to sign with, so it asks for
    /// nothing; signing in calls this, so a fresh install starts keeping its side of the bargain
    /// from its very first session rather than its second.
    func submit() {
        guard auth.isRegistered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        // Throwing here is ordinary rather than exceptional — the Simulator refuses outright, and
        // so does a device with Background App Refresh switched off. Neither is worth a word on
        // screen, and neither is something this app can do anything about.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// One pass: `syncInbox()` and nothing else.
    ///
    /// That is the holder half — collect deposits addressed to this device, process rotations and
    /// recovery metadata, emit the heartbeats that have come due — and it is exactly the beacon
    /// the trust model asks for, which is a holder reporting in rather than an owner auditing him.
    /// `syncDistributed()` is deliberately absent: it refreshes this device's view of its *own*
    /// holders, which nobody can see until the app is opened, and opening it syncs anyway.
    ///
    /// What runs daily is the poll, not the heartbeat. `emitHeartbeats` still guards each contact
    /// on its own three-day clock, so a pass that finds nothing due pushes nothing.
    func runPass() async {
        // Whatever happens below, the next pass has to be asked for: the modifier does not
        // reschedule itself, and returning early without submitting ends the chain until somebody
        // opens the app — which is the one thing this exists to stop depending on.
        defer { submit() }

        guard auth.isRegistered else { return }
        // `.unreadable` is a locked iPhone. Keys are `WhenUnlockedThisDeviceOnly`, so nothing here
        // could sign; say nothing, change nothing, ask again next pass. `.keysLost` sits out too —
        // there is no identity to beat with, and only the user can change that.
        guard auth.integrity == .intact else { return }

        do {
            try await shareManagement.syncInbox()
        } catch {
            // An unreachable relay is the ordinary case, not an error worth surfacing.
            return
        }

        // Best-effort, and last. Failing to announce must never undo a pass that already emitted
        // its heartbeats — the custody signal this exists for has gone out by now.
        let waiting = ((try? await shareManagement.listPendingRequests()) ?? [])
            .filter { $0.transactionType == .retrieval }
            .map(\.id)
        // Ids alone, on purpose: the notice may name nobody and no secret, and a signature that
        // cannot carry a name is a stronger guarantee of that than a comment asking for one.
        await RequestNotifier.announce(requestIds: waiting)
    }
}
