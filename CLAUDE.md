# iOS — Claude Code guidance

Platform-specific guidance for the `iOS/` repository. Cross-project context lives in `deposplit.com/CLAUDE.md` (loaded automatically when launching Claude from the workspace root via the `@`-import in `Deposplit/CLAUDE.md`).

## DONE: verify the BYOR / payload-signature changes

The recipient-side Ed25519 signature verification and BYOR (per deposplit.com/CLAUDE.md's "BYOR" section) work was implemented on Windows, where no Swift toolchain is actually installed on this machine (contrary to an earlier assumption) — so **none of it has been compiled or test-run**. Everything below was written carefully mirroring the already-verified Android/Kotlin and Scala implementations, but needs a real `swift build`/`swift test` pass:

```bash
# from iOS/hexagon/
swift build
swift test                                    # all tests
swift test --filter ShareServiceTests         # signature-verification + BYOR fan-out gating
swift test --filter PayloadCanonicalVectorTests  # cross-platform interop vector — must match the
                                                   # already-passing Scala/Kotlin fixtures byte-for-byte
swift test --filter IdentityServiceVerifyTests
```

Also worth an `xcodebuild build`/`xcodebuild test` pass on the `Deposplit.xcodeproj` app target (not just the `hexagon` package) since the UI-layer wiring (`DeposplitApp.swift`, `HomeView.swift`, `QrDisplayView(Model)`, `QrScanView`, `AddContactView(Model)`, new `ui/settings/`) hasn't been compiler-checked either.

Files most likely to have a small mistake, in rough order of risk:
- `hexagon/Sources/value_objects/PayloadCanonical.swift` — the cross-platform vector test will catch a wrong byte construction immediately if this is off.
- `hexagon/Sources/driving_adapters/ShareService.swift` — the fan-out/relay-resolution rewrite (`allRelays()`, `findShareRequest`, the `(relay:, request:)` tuple plumbing in `reconstruct`).
- `hexagon/Tests/ShareServiceTests.swift` / `PayloadCanonicalVectorTests.swift` — new test files, never compiled.
- `Deposplit/api/DeposplitRelayResolver.swift`, `Deposplit/settings/UserDefaultsRelaySettings.swift` — new app-layer adapters.

If `swift build` fails, the fix is almost certainly localized (a label/type mismatch) rather than a design problem — the Android/Kotlin port of the identical logic already compiles and passes 31/31 hexagon tests, and the Scala backend's version passes 88/88 tests, so the algorithm itself is proven; only the Swift transliteration is unverified.

## Toolchain

- Xcode 26+, Swift 6
- iOS 26+ deployment target (Apple's unified versioning, introduced 2025)
- SwiftUI (no UIKit, no storyboards except where UIViewControllerRepresentable is unavoidable)
- Swift Testing framework (not XCTest) — already in use in `ShamirSecretSharingTests.swift`

## Project structure

```
iOS/
├── hexagon/                          ← local Swift Package — domain boundary enforced by the build system
│   ├── Package.swift                 swift-tools-version: 6.0; platforms: iOS 26.4; path: "Sources"
│   └── Sources/
│       ├── shamir/
│       │   └── ShamirSecretSharing.swift  SSS split/combine over GF(2⁸); ShamirError
│       ├── driving_ports/
│       │   ├── Identity.swift             isRegistered, register, pseudonym, edPublicKey, xPublicKey, sign
│       │   ├── ShareManagement.swift      use-case interface: deposit, listSecrets, listDistributed (reads local store), syncDistributed,
│       │   │                              reconstruct (pure read, enforces real k), discardSecret, forceForgetSecret, syncInbox, listHeld (reads local store), respond, …
│       │   │                              pushRecoveryMetadata (item 8, holder side); pushRotation (item 9, client primitive only — no
│       │   │                              "regenerate my own identity" UI trigger exists yet, see deposplit.com/TODO.md item 9's scope-split note)
│       │   ├── ContactManagement.swift    listContacts, addManually, addFromQr, updateContact (item 8 — contact-update-in-place,
│       │   │                              key change forces a fresh verificationLevel), deleteContact
│       │   └── CatalogManagement.swift    exportCatalog, importCatalog — optional non-secret catalog backup (item 8)
│       ├── driven_ports/
│       │   ├── IdentityStore.swift        isRegistered, save, pseudonym, edPublicKey, edPrivateKey, xPublicKey, xPrivateKey
│       │   ├── ContactRepository.swift    getAll, getByEdKey, getById, save, delete
│       │   ├── ShareRepository.swift      getAll, getPlaintextShare (keyed on secretId, not the pickup relay-row id — item 8), save, delete
│       │   ├── SecretRepository.swift     getAll, save, delete — local store of sender-side Secret aggregates (item 11)
│       │   ├── ShareMetadataRepository.swift  getAll, save, delete — local store of distributed ShareMetadata
│       │   ├── ShareRelay.swift           openShareRequest (incl. k/n — item 8), listShareRequests, getShareRequest,
│       │   │                              respondToShareRequest, deleteShareRequest, deleteShareRequests, withdrawShareRequests
│       │   │                              (item 9 — best-effort tombstone, not a hard delete), pushRotation/listRotations/deleteRotation
│       │   │                              (item 9's signed rotate(K_old→K_new) push — grouped onto this port rather than a separate
│       │   │                              one since it's the same physical relay + BYOR routing; see KeyRotation.swift)
│       │   ├── ShareRelayResolver.swift   resolve(relayBaseUrl: String?): any ShareRelay — BYOR factory/cache; nil resolves to the device's default relay
│       │   └── RelaySettings.swift        defaultRelayBaseURL, setDefaultRelayBaseURL — device's runtime-configurable default relay
│       ├── services/
│       │   ├── IdentityService.swift      Identity + ShareEncryption impl — CryptoKit only, no Security/UserDefaults
│       │   ├── ShareEncryption.swift      intra-hexagon interface: encrypt, decrypt — implemented by IdentityService, used by ShareService
│       │   ├── ShareService.swift         ShareManagement impl — calls ShareRelay + ShareEncryption + ShareRepository + ShareMetadataRepository + SecretRepository + ContactRepository;
│       │   │                              deposit() writes ShareMetadata + a Secret to local store (incl. k/n on the deposit); listDistributed()/listSecrets() read from local store;
│       │   │                              syncDistributed() syncs field updates from relay (never deletes), then reconcileDiscarding() cleans up DISCARDING
│       │   │                              secrets whose holder removals were approved; syncInbox() also calls processRecoveryMetadata() (item 8, private —
│       │   │                              consumes approved inventory pushes verified against a known contact, rebuilding Secret/ShareMetadata);
│       │   │                              respond()'s retrieval/removal paths match the holder's HeldShare by secretId, not the sender's local shareId (item 8);
│       │   │                              reconstruct() is a pure read (item 11 — no teardown); discardSecret() flips a Secret to DISCARDING and fans out
│       │   │                              removal requests; forceForgetSecret() is the local-only escape hatch; pushRecoveryMetadata(contactId) opens a
│       │   │                              recoveryMetadata push for every HeldShare held from that contact (item 8); takes a new ContactManagement
│       │   │                              dependency (item 9) so processRotations() (private, called from syncInbox) can call updateContact after
│       │   │                              auto-verifying an incoming rotation notice against a known contact's trusted old key, downgrading the
│       │   │                              verification level to min(old, .low) per item 10's unifying rule; deleteHeldShare/deleteAllHeldFromSender
│       │   │                              best-effort withdraw via the sender's relay before deleting locally (item 9); syncDistributed() drops the
│       │   │                              local ShareMetadata pointer and deletes the relay row when it observes a .withdrawn deposit row
│       │   ├── ContactService.swift       ContactManagement impl — validates + delegates to ContactRepository; defines ContactError;
│       │   │                              updateContact requires a fresh verificationLevel whenever either key changes (item 8)
│       │   └── CatalogService.swift       CatalogManagement impl — exportCatalog/importCatalog (upsert-if-absent-by-id), item 8
│       └── value_objects/
│           ├── AuthError.swift            Error enum for auth failures
│           ├── Catalog.swift              Catalog struct (contacts, secrets, shareMetadata) — item 8's optional backup; Codable
│           ├── Contact.swift              Contact struct + VerificationLevel enum; Codable (for Catalog export/import)
│           ├── HeldShare.swift            HeldShare struct (incl. k/n — item 8, reported back to the owner during recovery)
│           ├── Secret.swift               Secret struct (id, label, k, n, secretCreatedAt, state) + SecretState enum (active/discarding) —
│           │                              sender-side per-secret aggregate, see CLAUDE.md item 11; Codable
│           ├── KeyRotation.swift          KeyRotation struct (item 9) — a signed rotate(K_old→K_new) notice addressed to this device;
│           │                              not a ShareRequest (no secretId, no consent phase)
│           └── Share.swift               Role, ShareTransactionType (incl. .inventory — item 8, self-approved, no consent phase),
│                                          ShareRequestState (incl. .withdrawn — item 9, deposit-only best-effort tombstone), ShareMetadata
│                                          (id/secretId/contactId only — label/secretCreatedAt live on Secret; Codable), ShareRequest (incl. k/n)
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target (adapters + UI); PBXFileSystemSynchronizedRootGroup
│   ├── DeposplitApp.swift            @main entry point + RootView (routes to SignInView or HomeView); wires
│   │                                  CatalogService alongside ShareService/ContactService (item 8)
│   ├── auth/
│   │   └── KeychainIdentityStore.swift  IdentityStore adapter — Security framework + UserDefaults
│   ├── api/
│   │   ├── DeposplitApiAdapter.swift  HTTP adapter — implements ShareRelay; URLSession + Ed25519 request signing (via Identity) + SHA-256 body hash;
│   │   │                              all /share-requests operations (incl. k/n — item 8); POST /share-requests/withdraw and
│   │   │                              POST/GET /key-rotations + DELETE /key-rotations/{id} (item 9)
│   │   └── DeposplitRelayResolver.swift  Implements ShareRelayResolver — memoizes one DeposplitApiAdapter per resolved base URL
│   ├── contacts/
│   │   └── LocalContactRepository.swift  JSON file in Documents/contacts.json
│   ├── settings/
│   │   └── UserDefaultsRelaySettings.swift  Implements RelaySettings — UserDefaults-backed default relay
│   ├── shares/
│   │   ├── LocalShareRepository.swift          JSON file in Documents/shares.json; plaintext share standard base64, contactId + senderPseudonym + k/n (item 8);
│   │   │                                        getPlaintextShare keyed on secretId (item 8)
│   │   ├── LocalSecretRepository.swift         JSON file in Documents/secrets.json; local store of sender-side Secret aggregates (item 11)
│   │   └── LocalShareMetadataRepository.swift  JSON file in Documents/distributed_shares.json; local store of distributed ShareMetadata; base64url keys, ISO-8601 timestamps
│   └── ui/
│       ├── SignInViewModel.swift      Registration flow (pseudonym input)
│       ├── SignInView.swift           Registration flow (pseudonym input)
│       ├── HomeView.swift            NavigationStack + TabView (Distributed/Held/Requests)
│       ├── home/
│       │   ├── HomeViewModel.swift   two-phase load: Phase 1 reads from device storage (always succeeds); Phase 2 syncs relay (sets syncWarning on failure);
│       │   │                        SecretGroup (wraps a Secret + its HolderStatus list) + SecretHealth (graduated n_live-vs-k badge, item 11);
│       │   │                        requestAll/discardSecret/forceForgetSecret via ShareManagement
│       │   ├── RequestsViewModel.swift  listPendingRequests + respond via ShareManagement; contact lookup via ContactManagement
│       │   ├── DistributedTab.swift  Per-secret grouped cards (item 11) → tapping a holder navigates to ShareDetailView via a ShareDetailTarget
│       │   │                        (secret + share); health badge, "Request Retrieval (all)", discard/force-forget actions; shows syncWarning banner
│       │   ├── HeldTab.swift         Read-only list of held shares; takes [Contact] for name resolution; shows syncWarning banner
│       │   └── RecipientRequestsTab.swift  Approve/deny incoming requests
│       ├── contacts/
│       │   ├── ContactsViewModel.swift  listContacts + deleteContact via ContactManagement
│       │   ├── ContactsView.swift    List + delete + add via QR or manual entry; per-row "Relink (Key Changed)" context-menu action (item 8)
│       │   ├── AddContactViewModel.swift  addManually via ContactManagement
│       │   ├── AddContactView.swift
│       │   └── RelinkContactView.swift + RelinkContactViewModel.swift  (item 8) Scans a re-presented QR code, calls
│       │                              contactManagement.updateContact then shareManagement.pushRecoveryMetadata; distinct
│       │                              from QrScanView, which always mints a *new* contact
│       ├── deposit/
│       │   ├── DepositViewModel.swift  deposit via ShareManagement; listContacts via ContactManagement; splitTimeWarnings
│       │   │                        (item 11's three non-blocking soft-warning axes, computed from k/n before deposit)
│       │   └── DepositView.swift     confirmationDialog surfaces splitTimeWarnings before an actual deposit if any apply
│       ├── sharedetail/
│       │   ├── ShareDetailViewModel.swift  Takes a ShareDetailTarget (Secret + ShareMetadata); open RETRIEVE/DELETE requests;
│       │   │                        reconstruct via ShareManagement (ready-threshold now reads Secret.k); contact lookup via ContactManagement
│       │   └── ShareDetailView.swift
│       ├── qr/
│       │   ├── QrPayload.swift       {"v":1,"pseudonym":"…","ed":"…","x":"…"} encode/decode
│       │   ├── QrDisplayViewModel.swift  CoreImage QR generation (synchronous, MainActor-safe)
│       │   ├── QrDisplayView.swift
│       │   └── QrScanView.swift      DataScannerViewController (VisionKit, iOS 16+) + QrScanViewModel; DataScannerRepresentable
│       │                              is internal (not private) so RelinkContactView (item 8) can reuse it
│       └── settings/
│           ├── SettingsView.swift    Default relay editor; "Catalog Backup" section (item 8) — export via ShareLink/.fileExporter,
│           │                        import via .fileImporter
│           └── SettingsViewModel.swift  relaySettings + catalogManagement; prepareCatalogExport/importCatalog(from:)
└── DeposplitTests/                   ← unit test target (@testable import hexagon)
    └── ShamirSecretSharingTests.swift
```

## Build & test

Tests run via Xcode (Product → Test) or from the command line:

```bash
# from iOS/ — requires Xcode command-line tools
xcodebuild build \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -sdk iphoneos \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# hexagon package tests only — no simulator required
swift test --package-path hexagon
```

## Continuous Integration

`.github/workflows/test.yml` runs `swift test` (`working-directory: hexagon`) on `macos-latest` for every push and for pull requests targeting `main` — Swift ships with the runner's Xcode install, so no separate setup step is needed. This covers only the `hexagon` Swift package; the `Deposplit.xcodeproj` app target (`xcodebuild test`) needs a simulator and is not yet part of CI. `.github/dependabot.yml` covers the `github-actions` and `swift` ecosystems on a weekly schedule; the latter is scoped to `/hexagon` and is currently a no-op since `hexagon/Package.swift` declares no external dependencies.

## Key decisions to preserve

- **iOS 26+ deployment target** — `IPHONEOS_DEPLOYMENT_TARGET = 26.4` in project settings. Do not lower.
- **All UI in SwiftUI** — no UIKit, no storyboards. `DataScannerViewController` is wrapped via `UIViewControllerRepresentable` for QR scanning.
- **Registration is keypair-first** — `CryptoKit.Curve25519.Signing.PrivateKey` (Ed25519) + `Curve25519.KeyAgreement.PrivateKey` (X25519). No OIDC, no password, no email. See `deposplit.com/CLAUDE.md` for rationale.
- **Private key storage** — raw 32-byte key material stored in iOS Keychain (`kSecClassGenericPassword`, service `com.deposplit.Deposplit`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Curve25519 is not supported by the Secure Enclave (which only handles P256), so software Keychain is used.
- **Public keys stored in Keychain too** — same service, separate account strings (`ed.public`, `x.public`). Pseudonym + `registered` flag in `UserDefaults`.
- **Share encryption uses CryptoKit**: X25519 key agreement → `sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: "deposplit-share", outputByteCount: 32)` → `ChaChaPoly.seal(plaintext, using: key, nonce: nonce)`. Wire format: `sealedBox.combined` = nonce(12) + ciphertext + tag(16).
- **API request signing**: SHA-256 body hash via `CryptoKit.SHA256.hash(data:)`, Ed25519 signature via `key.signature(for:)`.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — set in build settings. All types are `@MainActor` by default. Async network calls (`URLSession.data(for:)`) work fine since they suspend without blocking. CPU-bound operations (QR generation, SSS) are fast enough to run on the main actor.
- **`@Observable`** (not `ObservableObject` / `@Published`) for all ViewModels — iOS 17+, consistent with deployment target.
- **`NavigationStack`** (not the deprecated `NavigationView`).
- **`hexagon` is a local Swift Package** — domain code lives in `hexagon/Sources/` and is a separate SPM target linked into both the app and test targets. The compiler enforces the boundary: any attempt to `import SwiftUI`, `import Security`, or `import UIKit` from inside the package is a build error. Tests use `@testable import hexagon`. The app target uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+): any `.swift` file placed in `Deposplit/` is automatically compiled — no need to edit `project.pbxproj` when adding adapter or UI files.

## Boundary rule (enforced by the build system)

- Hexagon files (`hexagon/Sources/…`): may import `CryptoKit` and `Foundation` only; must NOT import `Security`, `UIKit`, `SwiftUI`, or `URLSession` — the package has no such dependencies so the compiler catches violations.
- Adapter files (`KeychainIdentityStore`, `DeposplitApiAdapter`, `LocalContactRepository`, `LocalShareRepository`, …): may import anything; add `import hexagon` to use domain types.

## DONE: ShareTransport → ShareRelay + ShareManagement + ShareService refactor

`ShareTransport.swift` in `hexagon/Sources/driving_ports/` is misclassified. It has no hexagon implementation (the app-layer `DeposplitApiAdapter` implements it directly), which means it is acting as a **driven port**, not a driving port. The correct Ports & Adapters structure, already applied in Android and the Scala `phon` hexagon, is:

```
driving_ports/ShareManagement.swift   ← use-case interface, implemented by ShareService inside the hexagon
driven_ports/ShareRelay.swift         ← raw relay API, called out by ShareService, implemented by DeposplitApiAdapter
services/ShareService.swift           ← hexagon service: implements ShareManagement
                                         calls ShareRelay + Identity + ShareRepository + ContactRepository
```

### Step 1 — Create `hexagon/Sources/driven_ports/ShareRelay.swift`

Move the full API from `ShareTransport.swift` here, renamed to `ShareRelay`:

```swift
public protocol ShareRelay {
    func depositShare(secretId: UUID, label: String, recipientKey: Data, ciphertext: Data) throws -> ShareMetadata
    func listShares(role: Role, counterpartyKey: Data?) throws -> [ShareMetadata]
    func pickUpShare(shareId: UUID) throws -> Data
    func deleteShare(shareId: UUID) throws
    func openShareRequest(shareId: UUID, type: ShareTransactionType) throws -> ShareRequest
    func listShareRequests(role: Role, state: ShareRequestState?) throws -> [ShareRequest]
    func getShareRequest(requestId: UUID) throws -> ShareRequest
    func respondToShareRequest(requestId: UUID, approved: Bool, ciphertext: Data?) throws -> ShareRequest
}
```

### Step 2 — Create `hexagon/Sources/driving_ports/ShareManagement.swift`

Use-case interface (the hexagon implements this):

```swift
public protocol ShareManagement {
    // Sender
    func deposit(secret: Data, label: String, contacts: [Contact], threshold: Int) throws
    func listDistributed() throws -> [ShareMetadata]
    func listSentRequests() throws -> [ShareRequest]
    func requestAll(secretId: UUID) throws
    func openRequest(shareId: UUID, type: ShareTransactionType) throws -> ShareRequest
    func reconstruct(secretId: UUID) throws -> Data

    // Recipient
    func syncInbox() throws
    func listHeld() throws -> [HeldShare]
    func listPendingRequests() throws -> [ShareRequest]
    func respond(requestId: UUID, approved: Bool) throws
    func deleteHeldShare(shareId: UUID) throws
    func deleteAllHeldFromSender(senderKey: Data) throws
}
```

### Step 3 — Create `hexagon/Sources/services/ShareService.swift`

Implements `ShareManagement`. Mirrors `ShareService.kt` / `ShareService.scala` exactly:

- `deposit`: `SecretSharing.split` → encrypt each share via `identity.encrypt` → `relay.depositShare`
- `listDistributed`: `relay.listShares(.sender)`
- `listSentRequests`: `relay.listShareRequests(.sender)`
- `requestAll`: fetch distributed + existing requests, open retrieve request for any holder without a pending/approved one
- `openRequest`: `relay.openShareRequest`
- `reconstruct`: fetch approved retrieve requests for `secretId`, decrypt each via `identity.decrypt` + look up contact's `xPublicKey`, `SecretSharing.combine`, delete relay rows
- `syncInbox`: `relay.listShares(.recipient)`, pick up and store any not yet in `shareRepository`
- `listHeld`: `shareRepository.getAll()`
- `listPendingRequests`: `relay.listShareRequests(.recipient, state: .pending)`
- `respond`: `relay.getShareRequest` → provide ciphertext from local store if approved retrieve → `relay.respondToShareRequest` → delete local if approved delete
- `deleteHeldShare` / `deleteAllHeldFromSender`: delegate to `shareRepository`

Use `try?` for best-effort cleanup calls (same as `runCatching` in Kotlin / `Try(...)` in Scala).

### Step 4 — Delete `hexagon/Sources/driving_ports/ShareTransport.swift`

### Step 5 — Update `Deposplit/api/DeposplitApiAdapter.swift`

Change conformance from `ShareTransport` to `ShareRelay`.

### Step 6 — Update `Deposplit/DeposplitApp.swift`

Wire `ShareService` in the app entry point:

```swift
let shareRepository = LocalShareRepository()
let shareManagement: any ShareManagement = ShareService(
    relay: DeposplitApiAdapter(identity: identityService),
    identity: identityService,
    shareRepository: shareRepository,
    contactRepository: contactRepository
)
```

Expose `shareManagement: any ShareManagement` (not the concrete adapter) as the property ViewModels receive.

### Step 7 — Update ViewModels

| ViewModel | Old dependencies | New dependencies |
|---|---|---|
| `HomeViewModel` | `transport: ShareTransport`, `shareRepository: ShareRepository` | `shareManagement: any ShareManagement` |
| `DepositViewModel` | `auth: Identity`, `transport: ShareTransport` | `shareManagement: any ShareManagement` |
| `ShareDetailViewModel` | `auth: Identity`, `transport: ShareTransport` | `shareManagement: any ShareManagement` |
| `RequestsViewModel` | `transport: ShareTransport`, `shareRepository: ShareRepository` | `shareManagement: any ShareManagement` |

Key call-site changes:
- `DepositViewModel`: remove `SecretSharing.split` + `identity.encrypt` calls; replace with `shareManagement.deposit(secret:label:contacts:threshold:)`
- `ShareDetailViewModel.reconstruct()`: remove decrypt + combine + cleanup; replace with `shareManagement.reconstruct(secretId:)` — convert returned `Data` to `String` in the ViewModel (UI concern)
- `HomeViewModel.load()`: replace inbox pickup loop and `shareRepository` calls with `shareManagement.syncInbox()` + `shareManagement.listHeld()`
- `HomeViewModel.requestAll()`: replace inline loop with `shareManagement.requestAll(secretId:)`
- `RequestsViewModel.respond()`: remove ciphertext lookup + delete local logic; replace with `shareManagement.respond(requestId:approved:)`

`contactRepository.getAll()` stays in ViewModels that need to resolve display names (contact pseudonyms from public keys).

### Step 8 — Update `iOS/CLAUDE.md` project structure table

Update `driving_ports/ShareTransport.swift` → `driving_ports/ShareManagement.swift` and add `driven_ports/ShareRelay.swift` and `services/ShareService.swift` to the package layout.

---

## DONE: ContactManagement driving port + ContactService refactor

`ContactsViewModel`, `AddContactViewModel`, and `QrScanViewModel` in the app target call `ContactRepository` (a driven port) directly, bypassing the hexagon. Business logic — key-size validation, `VerificationLevel` assignment, UUID and timestamp generation — leaks into the ViewModels. The correct structure, already applied in Android and the Scala `phon` hexagon, is:

```
driving_ports/ContactManagement.swift   ← use-case interface, implemented by ContactService inside the hexagon
services/ContactService.swift           ← hexagon service: implements ContactManagement
                                           enforces domain rules; delegates persistence to ContactRepository
```

### Step 1 — Create `hexagon/Sources/driving_ports/ContactManagement.swift`

```swift
public protocol ContactManagement {
    func listContacts() throws -> [Contact]
    func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws
    func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws
    func deleteContact(contactId: UUID) throws
}
```

### Step 2 — Create `hexagon/Sources/services/ContactService.swift`

Implements `ContactManagement`. Mirrors `ContactService.kt` / `ContactService.scala` exactly:

```swift
class ContactService: ContactManagement {
    private let contactRepository: any ContactRepository

    init(contactRepository: any ContactRepository) {
        self.contactRepository = contactRepository
    }

    func listContacts() throws -> [Contact] { try contactRepository.getAll() }

    func addManually(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws {
        guard !pseudonym.trimmingCharacters(in: .whitespaces).isEmpty else { throw ContactError.blankPseudonym }
        guard edPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        guard xPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        let now = Date()
        try contactRepository.save(Contact(
            id: UUID(),
            pseudonym: pseudonym.trimmingCharacters(in: .whitespaces),
            edPublicKey: edPublicKey,
            xPublicKey: xPublicKey,
            verificationLevel: .unverified,
            verifiedAt: nil,
            addedAt: now
        ))
    }

    func addFromQr(pseudonym: String, edPublicKey: Data, xPublicKey: Data) throws {
        guard !pseudonym.trimmingCharacters(in: .whitespaces).isEmpty else { throw ContactError.blankPseudonym }
        guard edPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        guard xPublicKey.count == 32 else { throw ContactError.invalidKeySize }
        let now = Date()
        try contactRepository.save(Contact(
            id: UUID(),
            pseudonym: pseudonym.trimmingCharacters(in: .whitespaces),
            edPublicKey: edPublicKey,
            xPublicKey: xPublicKey,
            verificationLevel: .verified,
            verifiedAt: now,
            addedAt: now
        ))
    }

    func deleteContact(contactId: UUID) throws { try contactRepository.delete(contactId: contactId) }
}

enum ContactError: Error {
    case blankPseudonym
    case invalidKeySize
}
```

### Step 3 — Update `Deposplit/DeposplitApp.swift`

Wire `ContactService` and expose `contactManagement: any ContactManagement` (not the concrete repository):

```swift
let contactRepository = LocalContactRepository()
let contactManagement: any ContactManagement = ContactService(contactRepository: contactRepository)
```

### Step 4 — Update ViewModels

| ViewModel | Old dependencies | New dependencies |
|---|---|---|
| `ContactsViewModel` | `contactRepository: any ContactRepository` | `contactManagement: any ContactManagement` |
| `AddContactViewModel` | `contactRepository: any ContactRepository` | `contactManagement: any ContactManagement` |
| `QrScanViewModel` | `contactRepository: any ContactRepository` | `contactManagement: any ContactManagement` |
| `DepositViewModel` | `contactRepository: any ContactRepository` | `contactManagement: any ContactManagement` |

Key call-site changes:
- `ContactsViewModel.load()`: replace `contactRepository.getAll()` with `contactManagement.listContacts()`
- `ContactsViewModel.delete()`: replace `contactRepository.delete(id:)` with `contactManagement.deleteContact(contactId:)`
- `AddContactViewModel.save()`: remove `Contact` construction, `VerificationLevel`, `UUID()`, `Date()`; replace with `contactManagement.addManually(pseudonym:edPublicKey:xPublicKey:)`. Keep base64url decoding and field-level error mapping in the ViewModel as UI concerns.
- `QrScanViewModel.onQrDecoded()`: remove `Contact` construction, `VerificationLevel.verified`, `UUID()`, `Date()`; replace with `contactManagement.addFromQr(pseudonym:edPublicKey:xPublicKey:)`
- `DepositViewModel.loadContacts()`: replace `contactRepository.getAll()` with `contactManagement.listContacts()`

`HomeViewModel` and `ShareDetailViewModel` also call `contactRepository.getAll()` to resolve display names. These are read-only lookups that belong in the UI layer (resolving a key to a pseudonym for display), not domain operations — route them through `contactManagement.listContacts()` instead.

### Step 5 — Update `iOS/CLAUDE.md` project structure table

- `driving_ports/ContactManagement.swift` (add)
- `services/ContactService.swift` (add)

---

## DONE: Merge `RequestSigner` back into `Identity` + extract `ShareEncryption`

The current iOS code has a `RequestSigner` driving port that was split out of `Identity`. This split has been reverted on Android and the Scala `phon` hexagon: `sign` belongs in `Identity` because `DeposplitApiAdapter` depends on *the* identity, not on some abstract signing capability. Only `ShareEncryption` (`encrypt`, `decrypt`) remains as a separate intra-hexagon interface.

Target state:

| Interface | Where | Used by |
|---|---|---|
| `Identity` | `driving_ports/` | UI layer + `DeposplitApiAdapter` (`isRegistered`, `register`, `pseudonym`, `edPublicKey`, `xPublicKey`, `sign`) |
| `ShareEncryption` | `services/` (intra-hexagon) | `ShareService` (`encrypt`, `decrypt`) |

### Step 1 — Add `sign` to `hexagon/Sources/driving_ports/Identity.swift`

```swift
public protocol Identity {
    func isRegistered() -> Bool
    func register(pseudonym: String) throws
    func pseudonym() -> String
    func edPublicKey() -> Data
    func xPublicKey() -> Data
    func sign(message: Data) throws -> Data
}
```

### Step 2 — Delete `hexagon/Sources/driving_ports/RequestSigner.swift`

### Step 3 — Update `hexagon/Sources/services/IdentityService.swift`

Remove `RequestSigner` from the conformance list:

```swift
class IdentityService: Identity, ShareEncryption { … }
```

(The `sign` implementation stays — it moves from satisfying `RequestSigner` to satisfying `Identity`.)

### Step 4 — Create `hexagon/Sources/services/ShareEncryption.swift`

`ShareEncryption` is an **intra-hexagon interface** — both its implementer (`IdentityService`) and its consumer (`ShareService`) live in the `services` layer.

```swift
protocol ShareEncryption {
    func encrypt(plaintext: Data, recipientXPublicKey: Data) throws -> Data
    func decrypt(noncePlusCiphertext: Data, recipientXPublicKey: Data) throws -> Data
}
```

### Step 5 — Update `hexagon/Sources/services/ShareService.swift`

Replace the `identity: any Identity` (or `signer: any RequestSigner`) constructor parameter for encryption with `encryption: any ShareEncryption`; update call sites (`identity.encrypt` / `signer.encrypt` → `encryption.encrypt`, etc.).

### Step 6 — Update `Deposplit/api/DeposplitApiAdapter.swift`

Replace `signer: any RequestSigner` with `identity: any Identity`; update call sites (`signer.sign` → `identity.sign`, `signer.edPublicKey()` → `identity.edPublicKey()`).

### Step 7 — Update `Deposplit/DeposplitApp.swift`

```swift
let identityService = IdentityService(store: keychainStore)
let shareManagement: any ShareManagement = ShareService(
    relay: DeposplitApiAdapter(identity: identityService),
    encryption: identityService,
    shareRepository: shareRepository,
    shareMetadataRepository: shareMetadataRepository,
    contactRepository: contactRepository
)
```

### Step 8 — Update `iOS/CLAUDE.md` project structure table

- Remove `driving_ports/RequestSigner.swift`
- Update `driving_ports/Identity.swift` description to include `sign`
- Update `services/IdentityService.swift` description to remove `RequestSigner`
- Update `services/ShareEncryption.swift` entry (add if not present)
- Update `Deposplit/api/DeposplitApiAdapter.swift` description (`via Identity`)

---

## DONE: Offline-capable home tabs (ShareMetadataRepository + two-phase load)

### Background

The Android (`:hexagon` + `:app`) and Scala (`deposplit.com/hexagons/phon`) hexagons were updated to persist distributed `ShareMetadata` on-device so the "My Shared Secrets" tab renders from device storage when the relay is unreachable. The reference implementations are `ShareService.kt`, `HomeViewModel.kt`, and `LocalShareMetadataRepository.kt` in `Android/`. Apply the same pattern here.

The architectural rationale: `ShareManagement.listDistributed()` previously called `relay.listShares(.sender)` directly, making the relay the source of truth. But the relay is designed to be a loseable mailbox. At `deposit()` time the sender already has all the `ShareMetadata` on-device — it should be persisted locally then, and the relay should only sync field updates (e.g. `pickedUpAt`) when online.

### Step 1 — Create `hexagon/Sources/driven_ports/ShareMetadataRepository.swift`

New driven port for the local distributed-share store:

```swift
public protocol ShareMetadataRepository {
    func getAll() throws -> [ShareMetadata]
    func save(_ share: ShareMetadata) throws
    func delete(shareId: UUID) throws
}
```

### Step 2 — Update `hexagon/Sources/driving_ports/ShareManagement.swift`

Add `syncDistributed()` to the sender section:

```swift
func syncDistributed() throws
```

### Step 3 — Update `hexagon/Sources/services/ShareService.swift`

Add `shareMetadataRepository: any ShareMetadataRepository` constructor parameter. Apply the same four changes as in `ShareService.kt`:

- `deposit(secret:label:contacts:threshold:)`: after each `relay.depositShare(...)`, call `try? shareMetadataRepository.save(metadata)`
- `syncDistributed()`: `try relay.listShares(.sender).forEach { try shareMetadataRepository.save($0) }` — only updates/inserts, **never deletes**; the relay can update field values (e.g. `pickedUpAt`) but cannot remove entries (that would re-establish the relay as source of truth for existence)
- `listDistributed()`: return `try shareMetadataRepository.getAll()` — local store only; never calls the relay
- `reconstruct(secretId:)`: after each `try? relay.deleteShare(req.share.id)`, also call `try? shareMetadataRepository.delete(shareId: req.share.id)`

### Step 4 — Create `Deposplit/shares/LocalShareMetadataRepository.swift`

JSON file adapter in `Documents/distributed_shares.json`. Mirror `LocalShareRepository.swift` — same Codable wire-type pattern, base64url for `senderKey` and `recipientKey`, ISO-8601 strings for timestamps. Implement upsert in `save` (replace by `id` if present, append if not).

### Step 5 — Update `Deposplit/DeposplitApp.swift`

Wire the new adapter:

```swift
let shareMetadataRepository = LocalShareMetadataRepository()
let shareManagement: any ShareManagement = ShareService(
    relay: DeposplitApiAdapter(signer: identityService),
    encryption: identityService,
    shareRepository: shareRepository,
    shareMetadataRepository: shareMetadataRepository,
    contactRepository: contactRepository
)
```

### Step 6 — Update `Deposplit/ui/home/HomeViewModel.swift`

Split `load()` into two phases (mirrors `HomeViewModel.kt`):

**Phase 1** (local only, always succeeds — renders immediately even when offline):
```swift
let contacts = try contactManagement.listContacts()
let distributed = try shareManagement.listDistributed()  // local store
let held = try shareManagement.listHeld()                 // local store
// build groupedSecrets with allRequests = [] (no request state yet) and heldShares
// update @Observable state immediately
```

**Phase 2** (relay sync — soft failure, never wipes Phase 1 results):
```swift
do {
    try shareManagement.syncInbox()
    try shareManagement.syncDistributed()
    let allRequests    = try shareManagement.listSentRequests()
    let freshDistributed = try shareManagement.listDistributed()
    let freshHeld      = try shareManagement.listHeld()
    // rebuild groupedSecrets with allRequests, update heldShares
} catch {
    syncWarning = true
}
```

Add `var syncWarning = false` to the `@Observable` `HomeViewModel`.

### Step 7 — Update tab views to show a soft warning banner

In `DistributedTab.swift` and `HeldTab.swift` (not `RecipientRequestsTab.swift`, which has its own error handling), show a small banner at the top when `homeViewModel.syncWarning` is `true`:

```swift
if homeViewModel.syncWarning {
    Label("Relay not reachable", systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
}
```

### Step 8 — Update `iOS/CLAUDE.md` project structure table

- `driven_ports/ShareMetadataRepository.swift` (add — local store of distributed `ShareMetadata`)
- `services/ShareService.swift` description: add `ShareMetadataRepository` dependency
- `shares/LocalShareMetadataRepository.swift` (add — `Documents/distributed_shares.json`)
- `home/HomeViewModel.swift` description: note two-phase load + `syncWarning`

---

## TODO: Biometric unlock for secret reconstruction

The Android app gates `viewModel.reconstruct()` behind `BiometricPrompt`. The iOS `ShareDetailView` currently calls `viewModel.reconstruct()` directly without any authentication gate.

Add biometric authentication using `LocalAuthentication`:

```swift
import LocalAuthentication

let context = LAContext()
var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
    // show explanatory message (no hardware / not enrolled)
    return
}
context.evaluatePolicy(
    .deviceOwnerAuthenticationWithBiometrics,
    localizedReason: String(localized: "Authenticate to reconstruct your secret")
) { success, authError in
    guard success else { return }
    Task { @MainActor in await viewModel.reconstruct() }
}
```

Gate it behind a `SKIP_BIOMETRIC` build flag (like Android does via `BuildConfig`) so it can be bypassed on simulators during development.
