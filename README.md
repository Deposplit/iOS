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
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target
│   ├── DeposplitApp.swift            @main entry + RootView (routes to SignInView or HomeView)
│   ├── ShamirSecretSharing.swift     SSS library (split / combine over GF(2⁸))
│   ├── auth/
│   │   ├── AuthPort.swift            Domain port protocol (Identity — pending rename)
│   │   ├── AuthService.swift         CryptoKit keypair generation, Ed25519 signing,
│   │   │                             X25519+HKDF-SHA-256+ChaCha20-Poly1305 encrypt/decrypt
│   │   │                             (IdentityService — pending rename)
│   │   ├── KeychainIdentityStore.swift  IdentityStore adapter — Keychain storage
│   │   └── SignInViewModel.swift
│   ├── api/
│   │   ├── ShareTransport.swift      Domain port protocol + value types
│   │   │                             (Role, ShareRequestType, ShareRequestState,
│   │   │                              ShareMetadata, ShareRequest)
│   │   └── DeposplitApiAdapter.swift  URLSession HTTP adapter — all 7 API operations,
│   │                                  Ed25519 request signing, SHA-256 body hash
│   ├── contacts/
│   │   ├── Contact.swift             Contact + VerificationLevel + ContactRepository protocol
│   │   └── LocalContactRepository.swift  JSON file in Documents folder
│   └── ui/
│       ├── SignInView.swift           Registration screen (pseudonym input)
│       ├── HomeView.swift            NavigationStack + TabView (3 tabs) + toolbar
│       ├── home/
│       │   ├── HomeViewModel.swift   listShares for both roles
│       │   ├── RequestsViewModel.swift  listShareRequests(recipient, pending) + respond
│       │   ├── DistributedTab.swift  Sender's distributed shares → taps to ShareDetailView
│       │   ├── HeldTab.swift         Recipient's held shares (read-only list)
│       │   └── RecipientRequestsTab.swift  Approve/deny incoming requests
│       ├── contacts/
│       │   ├── ContactsViewModel.swift
│       │   ├── ContactsView.swift    List + delete; add via menu (QR or manual)
│       │   ├── AddContactViewModel.swift
│       │   └── AddContactView.swift  Manual key entry (base64url)
│       ├── deposit/
│       │   ├── DepositViewModel.swift  Shamir.split → auth.encrypt → transport.depositShare
│       │   └── DepositView.swift
│       ├── sharedetail/
│       │   ├── ShareDetailViewModel.swift  Open RETRIEVE/DELETE requests;
│       │   │                               reconstruct via auth.decrypt + Shamir.combine
│       │   └── ShareDetailView.swift
│       └── qr/
│           ├── QrPayload.swift       {"v":1,"pseudonym":"…","ed":"…","x":"…"} encode/decode
│           ├── QrDisplayViewModel.swift  CoreImage QR code generation
│           ├── QrDisplayView.swift
│           └── QrScanView.swift      DataScannerViewController (VisionKit) + QrScanViewModel
└── DeposplitTests/
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

**Port (`Identity`)** — a Swift protocol defined by the domain. It expresses what the app needs without knowing anything about CryptoKit or Keychain.

**Service (`IdentityService`)** — implements the port using CryptoKit keypair generation, Ed25519 signing, and X25519+HKDF+ChaCha20-Poly1305 encryption. Delegates key persistence to the `IdentityStore` driven port.

**Adapter (`KeychainIdentityStore`)** — implements `IdentityStore` using the Security framework. Changing the storage strategy only requires changing this class.

**ViewModel (`SignInViewModel`)** — sits at the UI/domain boundary. It calls the port and holds the state that the view observes.

**`DeposplitApp`** — creates the adapters and passes them into the view hierarchy.

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
| 10 | Sim-A | Tap the Bob entry → **Open request** (Retrieve) |
| 11 | Sim-A | Tap the Carol entry → **Open request** (Retrieve) |
| 12 | Sim-B | **Requests** tab → a Retrieve request from Alice → tap **Approve** |
| 13 | Sim-C | **Requests** tab → a Retrieve request from Alice → tap **Approve** |
| 14 | Sim-A | Either Distributed entry → **Reconstruct secret…** button appears (both approved) → secret is displayed |

The threshold logic (`combine`) is tested in the unit tests; this flow validates the full path including encryption, transport, and decryption.

### Flow 2 — Deny and re-request

After step 8 above: Bob taps **Deny** → on Alice's side the Retrieve row shows "Denied" and a **Re-open** button → Alice re-opens the request → Bob approves.

### Flow 3 — Sender-initiated deletion

Alice taps **Open request** (Delete) on one of her Distributed shares → Bob's Requests tab shows a Delete request → Bob approves → verify the share is removed from Bob's Held tab.

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
- Contacts added by manual key entry have `verificationLevel = .unverified`; contacts added by QR scan have `verificationLevel = .verified` (shown with a green checkmark badge).

---

## What is next

The iOS app is feature-complete for v0.1. Planned improvements:

1. **Biometric unlock** — gate `ShareDetailView.reconstruct()` behind `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`, mirroring the Android `BiometricPrompt` implementation. See `iOS/CLAUDE.md` for the full implementation guide.
2. **Ports & Adapters fixes** — two architectural clean-ups carried out on Android are pending for iOS:
   - `ShareTransport` → `ShareRelay` (driven port) + `ShareManagement` (driving port, implemented by `ShareService` in the hexagon): SSS split/combine + encrypt/decrypt + relay coordination moves out of ViewModels into the domain layer.
   - `ContactManagement` driving port + `ContactService`: contact-addition logic (key validation, `VerificationLevel` assignment) moves out of `AddContactViewModel` / `QrScanViewModel` into the domain layer.
   See `iOS/CLAUDE.md` for step-by-step instructions for both refactors.
3. **Group Distributed tab by `secretId`** — same as the planned Android improvement: a 2-of-2 deposit produces two entries today; they should collapse into one logical-secret row.
4. **End-to-end test with production** — once `api.deposplit.com` is deployed, run the full flow against the live Web app/service.
