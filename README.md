# Deposplit — iOS

SwiftUI iOS app for [Deposplit](https://github.com/Deposplit/deposplit.com): a secret-sharing app built on Shamir's Secret Sharing (SSS). Secrets are split into *n* shares and distributed to contacts via the deposplit.com Web app/service; reconstruction requires at least *k* holders to cooperate.

This document is written for a developer who knows Swift well but has limited iOS / SwiftUI experience.

---

## Table of contents

1. [iOS concepts you need](#ios-concepts-you-need)
2. [Project structure](#project-structure)
3. [Architecture](#architecture)
4. [The registration flow](#the-registration-flow)
5. [Building and running](#building-and-running)
6. [Testing against a local Web app/service](#testing-against-a-local-Web app/service)
7. [What is next](#what-is-next)

---

## iOS concepts you need

### SwiftUI and the `App` protocol

iOS apps no longer need a `UIApplicationDelegate`. A struct marked `@main` that conforms to `App` is the entry point. Its `body` property returns a `Scene` — almost always a `WindowGroup` — that wraps the root `View`.

```swift
@main
struct DeposplitApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
```

### Views and `@Observable`

SwiftUI views are value types (`struct`) that describe what should appear on screen. They are redrawn whenever their observed state changes.

ViewModels in Deposplit use the `@Observable` macro (iOS 17+):

```swift
@Observable
final class HomeViewModel {
    var shares: [ShareMetadata] = []   // changing this triggers a view refresh
}
```

Inside a view, reference the ViewModel and SwiftUI tracks which properties are read:

```swift
struct HomeView: View {
    @State private var viewModel = HomeViewModel(...)
    var body: some View {
        Text("\(viewModel.shares.count) shares")  // re-renders when shares changes
    }
}
```

Use `@State` (not `@StateObject`) for `@Observable` objects owned by a view. Use `@Bindable` to create bindings to an `@Observable` object's properties (e.g., for `TextField`).

### NavigationStack and sheets

Navigation between screens uses `NavigationStack` with `.navigationDestination(for:)` or `.sheet(isPresented:)` for modal presentation:

```swift
NavigationStack {
    List(items) { item in
        NavigationLink(item.label, value: item)
    }
    .navigationDestination(for: MyType.self) { item in
        DetailView(item: item)
    }
}
```

Types used as navigation values must conform to `Hashable`.

### Tasks and async/await

Async work is triggered from views using the `.task` modifier (scoped to the view's lifetime) or a `Task { }` block inside a button action:

```swift
.task { await viewModel.load() }          // called on appear, cancelled on disappear

Button("Deposit") {
    Task { await viewModel.deposit() }    // fire-and-forget
}
```

All ViewModels and views run on the `@MainActor` by default (the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so async network calls via `URLSession` work without any explicit actor hopping.

### Keychain

Private keys are stored in the iOS **Keychain** via the `Security` framework (`SecItemAdd`, `SecItemCopyMatching`). Deposplit stores 32-byte raw key material as `kSecClassGenericPassword` items with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Curve25519 (Ed25519 + X25519) is not supported by the **Secure Enclave**, which only handles P256. Deposplit uses software-backed Keychain items.

### `#if DEBUG`

Swift's conditional compilation flag `DEBUG` is defined in the `Debug` build configuration (see `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in the project settings). Deposplit uses it to switch the Web app/service URL:

```swift
#if DEBUG
transport = DeposplitApiAdapter(auth: a, baseURL: "http://localhost:9000")
#else
transport = DeposplitApiAdapter(auth: a)
#endif
```

---

## Project structure

The project uses `PBXFileSystemSynchronizedRootGroup` (introduced in Xcode 16): **any `.swift` file added to the `Deposplit/` folder is automatically compiled** — there is no need to add files to `project.pbxproj` manually.

```
iOS/
├── hexagon/                          ← local Swift Package — domain boundary enforced by the build system
│   ├── Package.swift                 swift-tools-version: 6.0; platforms: iOS 26.4; path: "Sources"
│   └── Sources/
│       ├── shamir/
│       │   └── ShamirSecretSharing.swift  SSS split/combine over GF(2⁸); ShamirError
│       ├── driving_ports/
│       │   ├── Identity.swift             isRegistered, register, pseudonym, edPublicKey, xPublicKey,
│       │   │                              sign, encrypt, decrypt (Identity split into Identity + ShareEncryption
│       │   │                              + RequestSigner is pending — see iOS/CLAUDE.md)
│       │   ├── ShareManagement.swift      use-case interface: deposit, listSecrets, listDistributed,
│       │   │                              reconstruct (pure read, real k), discardSecret, forceForgetSecret,
│       │   │                              syncInbox, listPendingRequests, respond, pushRecoveryMetadata (item 8), …
│       │   ├── ContactManagement.swift    listContacts, addManually, addFromQr, updateContact (item 8 —
│       │   │                              contact-update-in-place, key change forces a fresh verificationLevel), deleteContact
│       │   └── CatalogManagement.swift    exportCatalog, importCatalog — optional non-secret catalog backup (item 8)
│       ├── driven_ports/
│       │   ├── IdentityStore.swift        isRegistered, save, pseudonym, edPublicKey, edPrivateKey,
│       │   │                              xPublicKey, xPrivateKey
│       │   ├── ContactRepository.swift    getAll, getByEdKey, getById, save, delete
│       │   ├── ShareRepository.swift      getAll, getPlaintextShare (keyed on secretId, not the pickup relay-row id — item 8), save, delete
│       │   ├── SecretRepository.swift     getAll, save, delete — local store of sender-side Secret aggregates (item 11)
│       │   ├── ShareMetadataRepository.swift  getAll, save, delete — local store of distributed ShareMetadata
│       │   ├── ShareRelay.swift           openShareRequest (incl. k/n — item 8), listShareRequests, getShareRequest,
│       │   │                              respondToShareRequest, deleteShareRequest, deleteShareRequests
│       │   ├── ShareRelayResolver.swift   resolve(relayBaseUrl:) — BYOR factory/cache; nil resolves to the device's default relay
│       │   └── RelaySettings.swift        defaultRelayBaseURL, setDefaultRelayBaseURL — device's runtime-configurable default relay
│       ├── services/
│       │   ├── IdentityService.swift      Identity + ShareEncryption impl — CryptoKit only, no Security/UserDefaults
│       │   ├── ShareEncryption.swift      Intra-hexagon interface: encrypt(plaintext, recipientXPublicKey),
│       │   │                              decrypt(noncePlusCiphertext, recipientXPublicKey)
│       │   ├── ShareService.swift         ShareManagement impl — calls ShareRelay + ShareEncryption +
│       │   │                              ShareRepository + ShareMetadataRepository + SecretRepository + ContactRepository;
│       │   │                              deposit() writes ShareMetadata + a Secret to local store (incl. k/n); listDistributed()/listSecrets()
│       │   │                              read from local store; reconstruct() is a pure read (item 11); discardSecret()/
│       │   │                              forceForgetSecret() are the teardown primitives; syncInbox() auto-approves pending PickUp requests
│       │   │                              then calls processRecoveryMetadata() (item 8); pushRecoveryMetadata(contactId) is the holder-side push
│       │   ├── ContactService.swift       ContactManagement impl — validates + delegates to
│       │   │                              ContactRepository; defines ContactError; updateContact requires a fresh
│       │   │                              verificationLevel whenever either key changes (item 8)
│       │   └── CatalogService.swift       CatalogManagement impl — exportCatalog/importCatalog (upsert-if-absent-by-id), item 8
│       └── value_objects/
│           ├── AuthError.swift            Error enum for auth failures
│           ├── Catalog.swift              Catalog struct (contacts, secrets, shareMetadata) — item 8's optional backup; Codable
│           ├── Contact.swift              Contact struct + VerificationLevel enum; Codable
│           ├── HeldShare.swift            HeldShare struct (incl. k/n — item 8)
│           ├── Secret.swift               Secret struct (id, label, k, n, secretCreatedAt, state) + SecretState —
│           │                              sender-side per-secret aggregate, see CLAUDE.md item 11; Codable
│           └── Share.swift               Role, ShareRequestType (incl. .recoveryMetadata — item 8), ShareRequestState,
│                                          ShareMetadata (id/secretId/contactId only; Codable), ShareRequest (incl. k/n)
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target (adapters + UI); PBXFileSystemSynchronizedRootGroup
│   ├── DeposplitApp.swift            @main entry point + RootView (routes to SignInView or HomeView); wires
│   │                                  CatalogService alongside ShareService/ContactService (item 8)
│   ├── auth/
│   │   └── KeychainIdentityStore.swift  IdentityStore adapter — Security framework + UserDefaults
│   ├── api/
│   │   ├── DeposplitApiAdapter.swift  HTTP adapter — implements ShareRelay; URLSession + Ed25519 request
│   │   │                              signing + SHA-256 body hash; all /share-requests operations (incl. k/n — item 8)
│   │   └── DeposplitRelayResolver.swift  Implements ShareRelayResolver — memoizes one adapter per resolved base URL
│   ├── contacts/
│   │   └── LocalContactRepository.swift  JSON file in Documents/contacts.json
│   ├── settings/
│   │   └── UserDefaultsRelaySettings.swift  Implements RelaySettings
│   ├── shares/
│   │   ├── LocalShareRepository.swift          JSON file in Documents/shares.json; incl. k/n (item 8); getPlaintextShare keyed on secretId
│   │   ├── LocalSecretRepository.swift         JSON file in Documents/secrets.json; local store of sender-side Secret aggregates
│   │   └── LocalShareMetadataRepository.swift  JSON file in Documents/distributed_shares.json; local store of distributed ShareMetadata
│   └── ui/
│       ├── SignInViewModel.swift      Registration flow (pseudonym input)
│       ├── SignInView.swift           Registration screen
│       ├── HomeView.swift            NavigationStack + TabView (Distributed/Held/Requests)
│       ├── home/
│       │   ├── HomeViewModel.swift   syncInbox + listSecrets + listDistributed + listHeld via ShareManagement;
│       │   │                        SecretGroup (wraps a Secret) + SecretHealth badge; requestAll/discardSecret/forceForgetSecret (item 11)
│       │   ├── RequestsViewModel.swift  listPendingRequests + respond via ShareManagement
│       │   ├── DistributedTab.swift  Per-secret grouped cards (item 11) → tapping a holder navigates to ShareDetailView
│       │   │                        via a ShareDetailTarget (secret + share); health badge, discard/force-forget actions
│       │   ├── HeldTab.swift         Read-only list of held shares
│       │   └── RecipientRequestsTab.swift  Approve/deny incoming requests
│       ├── contacts/
│       │   ├── ContactsViewModel.swift  listContacts + deleteContact via ContactManagement
│       │   ├── ContactsView.swift    List + delete + add via QR or manual entry; per-row "Relink (Key Changed)" action (item 8)
│       │   ├── AddContactViewModel.swift  addManually via ContactManagement
│       │   ├── AddContactView.swift
│       │   └── RelinkContactView.swift + RelinkContactViewModel.swift  (item 8) QR re-scan → updateContact + pushRecoveryMetadata;
│       │                              distinct from QrScanView, which always mints a *new* contact
│       ├── deposit/
│       │   ├── DepositViewModel.swift  deposit via ShareManagement; listContacts via ContactManagement; splitTimeWarnings (item 11)
│       │   └── DepositView.swift     confirmationDialog surfaces splitTimeWarnings before deposit if any apply
│       ├── sharedetail/
│       │   ├── ShareDetailViewModel.swift  Takes a ShareDetailTarget (Secret + ShareMetadata); open RETRIEVE/DELETE
│       │   │                        requests; reconstruct via ShareManagement (ready-threshold reads Secret.k)
│       │   └── ShareDetailView.swift
│       ├── qr/
│       │   ├── QrPayload.swift       {"v":1,"pseudonym":"…","ed":"…","x":"…"} encode/decode
│       │   ├── QrDisplayViewModel.swift  CoreImage QR generation
│       │   ├── QrDisplayView.swift
│       │   └── QrScanView.swift      DataScannerViewController (VisionKit) + QrScanViewModel; DataScannerRepresentable
│       │                              is shared (not private) with RelinkContactView (item 8)
│       └── settings/
│           ├── SettingsView.swift    Default relay editor; "Catalog Backup" export/import (item 8)
│           └── SettingsViewModel.swift
└── DeposplitTests/                   ← unit test target (@testable import hexagon)
    └── ShamirSecretSharingTests.swift  Swift Testing — round-trip and cross-platform vectors
```

---

## Architecture

Deposplit follows **Ports & Adapters (Hexagonal Architecture)** for the domain and infrastructure layers. The UI layer uses MVVM with `@Observable`.

```
┌──────────────────────────────────────────────────────┐
│  UI Layer (SwiftUI)                                  │
│  SignInView ──► SignInViewModel                      │
└─────────────────────────┬────────────────────────────┘
                          │ calls port protocol
┌─────────────────────────▼────────────────────────────┐
│  Domain (Port)                                       │
│  Identity  ◄──── IdentityService (Service)           │
└──────────────────────────────────────────────────────┘
```

**Driving ports** (`Identity`, `ShareManagement`, `ContactManagement`) — Swift protocols defined by the domain; implemented by hexagon services. `Identity` includes `sign`; encryption/decryption is handled by the `ShareEncryption` intra-hexagon interface implemented by `IdentityService`.

**Services** (`IdentityService`, `ShareService`, `ContactService`) — implement the driving ports using CryptoKit (no Security/UserDefaults imports). Delegate infrastructure concerns to driven ports.

**Driven ports** (`IdentityStore`, `ShareRelay`, `ContactRepository`, `ShareRepository`) — implemented by infrastructure adapters in the app target.

**Adapters** (`KeychainIdentityStore`, `DeposplitApiAdapter`, `LocalContactRepository`, `LocalShareRepository`) — implement the driven ports using Security, URLSession, and the file system.

**ViewModel / UI layer** — ViewModels call only driving ports; they are unaware of adapters.

**`DeposplitApp`** — wires everything together: constructs adapters, creates services, exposes driving-port references to the view hierarchy.

Like Android's `:hexagon` Gradle module, the iOS domain code lives in its own **local Swift Package** (`iOS/hexagon/`), which is a separate SPM target linked into both the app and the test target. The compiler enforces the boundary: the package has no `Security`, `UIKit`, `SwiftUI`, or `URLSession` dependencies, so any accidental import is a build error.

---

## The registration flow

Deposplit does not use OIDC, passwords, or email. Registration is keypair-first.

```
1. User enters a pseudonym (display name only — no personal information required)
        │
2. App generates an Ed25519 keypair (API auth) and an X25519 keypair (share encryption)
        │  via CryptoKit: Curve25519.Signing.PrivateKey + Curve25519.KeyAgreement.PrivateKey
        │
3. Both private keys are stored as raw bytes in the iOS Keychain
        │  (kSecClassGenericPassword, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        │  Pseudonym + "registered" flag stored in UserDefaults
        │
4. DeposplitApp.RootView re-renders: isRegistered becomes true → shows HomeView
        │  No server call — the keypair IS the identity
```

---

## Building and running

### Prerequisites

- **Xcode 26** (or later) — required for iOS 26 SDK and the simulator
- **iOS 26 Simulator** — create one in Xcode → Window → Devices and Simulators → Simulators tab
- A physical iOS device running iOS 26+ is optional (requires a valid signing identity)

### Open the project

```bash
open iOS/Deposplit.xcodeproj
```

Select a simulator target (e.g., iPhone 16) and press **Run ▶ (⌘R)**.

### Build from the command line

```bash
# from iOS/
xcodebuild build \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Run the tests

Tests use the **Swift Testing** framework and run against the app target:

```bash
xcodebuild test \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Or in Xcode: **Product → Test (⌘U)**.

### First run

On first launch the app shows the sign-in screen. Enter a pseudonym (display name only — stored locally, never sent to the Web app/service). Tapping **Get started** generates Ed25519 and X25519 keypairs via CryptoKit, stores the private keys in the Keychain, and navigates to the home screen.

### Continuous Integration

A GitHub Actions workflow (`.github/workflows/test.yml`) runs `swift test` against the `hexagon` Swift package on `macos-latest` for every push and on pull requests targeting `main`. The `Deposplit.xcodeproj` app target isn't covered yet — that needs a simulator. Dependabot (`.github/dependabot.yml`) keeps GitHub Actions and Swift Package Manager dependencies (scoped to `/hexagon`) current on a weekly schedule.

---

## Testing against a local Web app/service

### Setup

**Start the Web app/service** (from `deposplit.com/`):

```bash
sbt run -Dconfig.file=conf/localhost.conf
```

It listens on port 9000. Unlike the Android emulator (which uses the special alias `10.0.2.2`), the **iOS Simulator shares the host machine's network stack** — it reaches the Web app/service simply via `localhost`. The debug build is wired to `http://localhost:9000` automatically via `#if DEBUG` in `DeposplitApp.swift`.

**Run the app** in Xcode: select a simulator and press **Run ▶**. The scheme is always `Debug` during development.

> **Note on real devices:** A physical iOS device on the same Wi-Fi network reaches your Mac via its LAN IP (e.g., `http://192.168.1.100:9000`). Change the `#if DEBUG` URL in `DeposplitApp.swift` accordingly, and add that IP (with port) to `play.filters.hosts.allowed` in `conf/localhost.conf`.

### Three-simulator setup

You need **three simulator instances** to exercise the full social flow with a 2-of-2 threshold split across two holders. In Xcode you can only run one simulator at a time from the Run button, but you can launch additional simulators via **Xcode → Open Developer Tool → Simulator**, then from within the Simulator app go to **File → Open Simulator** and choose another device model. Each instance runs the same app from the same build.

> **Tip:** Mixing platforms works well — run Alice on an iOS Simulator, Bob on an Android emulator, and test cross-platform interoperability at the same time.

### Flow 1 — Happy path (2-of-2 threshold, 2 holders)

| Step | Device | What to do |
|---|---|---|
| 1 | Sim-A | Launch → register as "Alice" |
| 2 | Sim-B | Launch → register as "Bob" |
| 3 | Sim-C | Launch → register as "Carol" |
| 4 | Sim-A | TopAppBar QR icon → Alice's QR code appears |
| 5 | Sim-B | Contacts (person icon) → **+** → **Enter Keys Manually** → paste Alice's keys; then show Bob's QR |
| 6 | Sim-C | Same: add Alice as contact; show Carol's QR |
| 7 | Sim-A | Add Bob and Carol as contacts (manual entry or QR) |
| 8 | Sim-A | **+** (top right) → enter a label (e.g. "test secret") and a secret, toggle Bob and Carol on, threshold = 2 → **Deposit** |
| 9 | Sim-A | **Distributed** tab → two entries appear (one per share/recipient, same `secretId`) |
| 10 | Sim-B | **Their Secret Shares** tab → Bob's inbox shows Alice's PickUp request → app auto-approves it, decrypts the share, and stores it as plaintext locally; relay clears the ciphertext |
| 11 | Sim-C | **Their Secret Shares** tab → Carol's inbox shows Alice's PickUp request → app auto-approves the same way |
| 12 | Sim-A | Tap the Bob entry → **Open request** (Retrieve) |
| 13 | Sim-A | Tap the Carol entry → **Open request** (Retrieve) |
| 14 | Sim-B | **Requests** tab → a Retrieve request from Alice → tap **Approve** |
| 15 | Sim-C | **Requests** tab → a Retrieve request from Alice → tap **Approve** |
| 16 | Sim-A | Either Distributed entry → **Reconstruct secret…** button appears (both approved) → secret is displayed |

The threshold logic (`combine`) is tested in the unit tests; this flow validates the full path including encryption, transport, and decryption.

### Flow 2 — Deny and re-request

After step 12 above: Bob taps **Deny** → on Alice's side the Retrieve row shows "Denied" and a **Re-open** button → Alice re-opens the request → Bob approves.

### Flow 3 — Sender-initiated deletion

Alice taps **Open request** (Delete) on one of her Distributed shares → Bob's Requests tab shows a Delete request → Bob approves → Bob's PickUp row is deleted (cascade-deleting any related Retrieve/Delete rows) → the share disappears from Bob's Held tab.

### Flow 4 — Recipient-initiated deletion

On Sim-B, swipe to delete Alice's share from the Held tab. The share disappears locally without any request. Verify what Alice's Distributed tab shows on refresh.

### Flow 5 — Error states

Kill the Web app/service (`Ctrl-C`) → pull-to-refresh or tap the ↺ button on either device → error banner appears. Restart the Web app/service → tap ↺ → data loads again.

### Flow 6 — Cross-platform (iOS + Android)

Run Alice on an iOS Simulator and Bob on an Android emulator simultaneously. They connect to the same `sbt run` Web app/service. Alice deposits a share for Bob; Bob (on Android) sees it in the Held tab. Bob opens a Retrieve request; Alice (on iOS) reconstructs. This validates the cross-platform E2EE compatibility: CryptoKit (iOS) and BouncyCastle (Android) produce identical X25519+HKDF+ChaCha20-Poly1305 wire bytes.

### Key edge cases to verify

- Re-registering (delete and reinstall the app) generates fresh keypairs — existing contacts cannot decrypt new shares with the old keys.
- The **Reconstruct secret…** button is hidden until ≥ 2 approved retrieve shares exist for the same `secretId`.
- 2-of-3 threshold: split across three contacts, have only two approve — the secret should still reconstruct.
- Contacts added by manual key entry default to `verificationLevel = .veryLow` and can be raised to `.low`/`.high` via the level picker (`.veryHigh` is not offered — it requires physical co-presence); contacts added by QR scan default to `.veryHigh` (shown with a colored level badge; no badge at `.veryLow`).

---

## What is next

The iOS app is feature-complete for v0.1. Planned improvements:

1. **Biometric unlock** — gate `ShareDetailView.reconstruct()` behind `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`, mirroring the Android `BiometricPrompt` implementation. See `iOS/CLAUDE.md` for the full implementation guide.
2. **End-to-end test with production** — once `api.deposplit.com` is deployed, run the full flow against the live Web app/service.
