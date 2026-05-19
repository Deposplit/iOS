# iOS — Claude Code guidance

Platform-specific guidance for the `iOS/` repository. Cross-project context lives in `deposplit.com/CLAUDE.md` (loaded automatically when launching Claude from the workspace root via the `@`-import in `Deposplit/CLAUDE.md`).

## Toolchain

- Xcode 26+, Swift 6
- iOS 26+ deployment target (Apple's unified versioning, introduced 2025)
- SwiftUI (no UIKit, no storyboards except where UIViewControllerRepresentable is unavoidable)
- Swift Testing framework (not XCTest) — already in use in `ShamirSecretSharingTests.swift`

## Project structure

**NOTE: the domain files are currently in topic-based folders (`auth/`, `api/`, `contacts/`, `shares/`). A refactoring TODO is listed at the end of this file. The structure below shows the desired target layout.**

```
iOS/
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target sources (PBXFileSystemSynchronizedRootGroup — all .swift files are compiled automatically)
│   ├── DeposplitApp.swift            @main entry point + RootView (routes to SignInView or HomeView)
│   ├── shamir/
│   │   └── ShamirSecretSharing.swift SSS library (part of app target)
│   ├── driving_ports/
│   │   ├── Identity.swift            Driving port: isRegistered, register, pseudonym, edPublicKey, xPublicKey, sign, encrypt, decrypt
│   │   └── ShareTransport.swift      Driving port + value types (Role, ShareRequestType, ShareRequestState, ShareMetadata, ShareRequest)
│   ├── driven_ports/
│   │   ├── IdentityStore.swift       Driven port: isRegistered, save, pseudonym, edPublicKey, edPrivateKey, xPublicKey, xPrivateKey
│   │   ├── ContactRepository.swift   Driven port: getAll, getByEdKey, save, delete
│   │   └── ShareRepository.swift     Driven port: getAll, getCiphertext, save, delete (local share storage)
│   ├── services/
│   │   └── IdentityService.swift     Identity implementation — CryptoKit only, no Security/UserDefaults
│   ├── value_objects/
│   │   ├── AuthError.swift           Error enum for auth failures
│   │   ├── Contact.swift             Contact struct + VerificationLevel enum
│   │   ├── HeldShare.swift           HeldShare struct
│   │   └── Share.swift               Role, ShareRequestType, ShareRequestState, ShareMetadata, ShareRequest
│   ├── auth/
│   │   └── KeychainIdentityStore.swift  IdentityStore adapter — Security framework + UserDefaults
│   ├── api/
│   │   └── DeposplitApiAdapter.swift  HTTP adapter: URLSession + Ed25519 request signing + SHA-256 body hash
│   │                                  pickUpShare (GET /shares/:shareId) + ciphertext-on-approve (PATCH /share-requests/:id)
│   ├── contacts/
│   │   └── LocalContactRepository.swift  JSON file in Documents/ folder
│   ├── shares/
│   │   └── LocalShareRepository.swift  JSON file in Documents/shares.json; ciphertext standard base64, senderKey base64url
│   └── ui/
│       ├── SignInViewModel.swift      Registration flow (pseudonym input)
│       ├── SignInView.swift           Registration flow (pseudonym input)
│       ├── HomeView.swift            NavigationStack + TabView (Distributed/Held/Requests)
│       ├── home/
│       │   ├── HomeViewModel.swift   listShares(sender) + listShares(recipient)
│       │   ├── RequestsViewModel.swift  listShareRequests(recipient, pending) + respondToShareRequest
│       │   ├── DistributedTab.swift  Tappable share rows → ShareDetailView
│       │   ├── HeldTab.swift         Read-only list of held shares
│       │   └── RecipientRequestsTab.swift  Approve/deny incoming requests
│       ├── contacts/
│       │   ├── ContactsViewModel.swift
│       │   ├── ContactsView.swift    List + delete + add via QR or manual entry
│       │   ├── AddContactViewModel.swift
│       │   └── AddContactView.swift
│       ├── deposit/
│       │   ├── DepositViewModel.swift  Shamir.split → auth.encrypt → transport.depositShare
│       │   └── DepositView.swift
│       ├── sharedetail/
│       │   ├── ShareDetailViewModel.swift  Open RETRIEVE/DELETE requests; reconstruct via auth.decrypt + Shamir.combine
│       │   └── ShareDetailView.swift
│       └── qr/
│           ├── QrPayload.swift       {"v":1,"pseudonym":"…","ed":"…","x":"…"} encode/decode
│           ├── QrDisplayViewModel.swift  CoreImage QR generation (synchronous, MainActor-safe)
│           ├── QrDisplayView.swift
│           └── QrScanView.swift      DataScannerViewController (VisionKit, iOS 16+) + QrScanViewModel
└── DeposplitTests/                   ← unit test target
    └── ShamirSecretSharingTests.swift
```

## Build & test

Tests run via Xcode (Product → Test) or from the command line:

```bash
# from iOS/ — requires Xcode command-line tools
xcodebuild build \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project Deposplit.xcodeproj \
  -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

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
- **SSS is not a separate Swift Package** — `ShamirSecretSharing.swift` is compiled directly into the app target. Tests use `@testable import Deposplit`.
- **No separate hexagon target** — unlike Android (which has a `:hexagon` Gradle module), all Swift code is in the single `Deposplit` app target. Domain protocols (`Identity`, `ShareTransport`, `ContactRepository`) enforce the Ports & Adapters boundary by convention, not by the build system. The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+): any `.swift` file placed in `Deposplit/` is automatically compiled — no need to edit `project.pbxproj` when adding source files.

## Boundary rule (enforced by convention, not build system)

- Domain files (`Identity`, `IdentityStore`, `IdentityService`, `ShamirSecretSharing`, `ShareTransport`, `Contact`, `HeldShare`, …): may import `CryptoKit` and `Foundation`; must NOT import `Security`, `UIKit`, `SwiftUI`, or `URLSession`.
- Adapter files (`KeychainIdentityStore`, `DeposplitApiAdapter`, `LocalContactRepository`, `LocalShareRepository`, …): may import anything.

## TODO: Hexagon directory refactoring

The domain files currently live in topic-based folders (`auth/`, `api/`, `contacts/`, `shares/`) that do not reflect the Ports & Adapters roles. They should be reorganised into role-based folders to match the Android hexagon and the relay hexagon. **This has not been done yet** — do it on macOS.

### File moves (create new file, delete old file)

Because the project uses `PBXFileSystemSynchronizedRootGroup`, no `project.pbxproj` edits are needed — just place `.swift` files in `Deposplit/` subdirectories and Xcode picks them up automatically.

| Old path (topic-based) | New path (role-based) | Notes |
|---|---|---|
| `ShamirSecretSharing.swift` | `shamir/ShamirSecretSharing.swift` | No content changes |
| `auth/AuthPort.swift` | `driving_ports/Identity.swift` | Rename protocol `AuthPort` → `Identity` |
| `auth/AuthError.swift` | `value_objects/AuthError.swift` | No content changes |
| `auth/IdentityStore.swift` | `driven_ports/IdentityStore.swift` | No content changes |
| `auth/AuthService.swift` | `services/IdentityService.swift` | Rename class `AuthService` → `IdentityService`; update conformance to `Identity` |
| `auth/SignInViewModel.swift` | `ui/SignInViewModel.swift` | No content changes; no import updates needed (same module) |
| `contacts/Contact.swift` | Split into two files: | See below |
| | `value_objects/Contact.swift` | Contains `VerificationLevel` enum + `Contact` struct only |
| | `driven_ports/ContactRepository.swift` | Contains `ContactRepository` protocol only |
| `shares/HeldShare.swift` | Split into two files: | See below |
| | `value_objects/HeldShare.swift` | Contains `HeldShare` struct only |
| | `driven_ports/ShareRepository.swift` | Contains `ShareRepository` protocol only |
| `api/ShareTransport.swift` | Split into two files: | See below — **read the SwiftUI note** |
| | `value_objects/Share.swift` | Contains `Role`, `ShareRequestType`, `ShareRequestState`, `ShareMetadata`, `ShareRequest` |
| | `driving_ports/ShareTransport.swift` | Contains `ShareTransport` protocol only |

**Adapter files that stay in place** (no moves needed):
- `auth/KeychainIdentityStore.swift`
- `api/DeposplitApiAdapter.swift`
- `contacts/LocalContactRepository.swift`
- `shares/LocalShareRepository.swift`

### SwiftUI boundary violation to fix

`api/ShareTransport.swift` currently imports `SwiftUI` to use `LocalizedStringKey` in two computed properties:

```swift
// ShareRequestType
var localizedLabel: LocalizedStringKey { ... }

// ShareRequestState  
var localizedLabel: LocalizedStringKey { ... }
```

This violates the boundary rule — domain value objects must not import SwiftUI. When creating `value_objects/Share.swift`, **remove these `localizedLabel` properties entirely**. The UI layer already uses `stringResource(R.string.share_request_retrieve)` style lookups on Android; do the equivalent in SwiftUI (pass the enum directly to a helper or use a `switch` in the view).

### After the file moves

Verify that:
1. `DeposplitApiAdapter.swift` imports are updated (it references `ShareTransport`, `Role`, `ShareMetadata`, `ShareRequest`, `ShareRequestType`, `ShareRequestState` — all will now live in `value_objects/` and `driving_ports/`)
2. All ViewModels import from the new locations
3. The build succeeds (`xcodebuild build` or Product → Build in Xcode)

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
