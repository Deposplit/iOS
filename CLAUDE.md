# iOS — Claude Code guidance

Platform-specific guidance for the `iOS/` repository. Cross-project context lives in `deposplit.com/CLAUDE.md` (loaded automatically when launching Claude from the workspace root via the `@`-import in `Deposplit/CLAUDE.md`).

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
│       │   ├── Identity.swift             isRegistered, register, pseudonym, edPublicKey, xPublicKey, sign, encrypt, decrypt
│       │   └── ShareTransport.swift       depositShare, listShares, pickUpShare, deleteShare, share-request CRUD
│       ├── driven_ports/
│       │   ├── IdentityStore.swift        isRegistered, save, pseudonym, edPublicKey, edPrivateKey, xPublicKey, xPrivateKey
│       │   ├── ContactRepository.swift    getAll, getByEdKey, save, delete
│       │   └── ShareRepository.swift      getAll, getCiphertext, save, delete
│       ├── services/
│       │   └── IdentityService.swift      Identity impl — CryptoKit only, no Security/UserDefaults
│       └── value_objects/
│           ├── AuthError.swift            Error enum for auth failures
│           ├── Contact.swift              Contact struct + VerificationLevel enum
│           ├── HeldShare.swift            HeldShare struct
│           └── Share.swift               Role, ShareRequestType, ShareRequestState, ShareMetadata, ShareRequest
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target (adapters + UI); PBXFileSystemSynchronizedRootGroup
│   ├── DeposplitApp.swift            @main entry point + RootView (routes to SignInView or HomeView)
│   ├── auth/
│   │   └── KeychainIdentityStore.swift  IdentityStore adapter — Security framework + UserDefaults
│   ├── api/
│   │   └── DeposplitApiAdapter.swift  HTTP adapter: URLSession + Ed25519 request signing + SHA-256 body hash
│   │                                  pickUpShare (GET /shares/:shareId) + ciphertext-on-approve (PATCH /share-requests/:id)
│   ├── contacts/
│   │   └── LocalContactRepository.swift  JSON file in Documents/contacts.json
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
- **`hexagon` is a local Swift Package** — domain code lives in `hexagon/Sources/` and is a separate SPM target linked into both the app and test targets. The compiler enforces the boundary: any attempt to `import SwiftUI`, `import Security`, or `import UIKit` from inside the package is a build error. Tests use `@testable import hexagon`. The app target uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+): any `.swift` file placed in `Deposplit/` is automatically compiled — no need to edit `project.pbxproj` when adding adapter or UI files.

## Boundary rule (enforced by the build system)

- Hexagon files (`hexagon/Sources/…`): may import `CryptoKit` and `Foundation` only; must NOT import `Security`, `UIKit`, `SwiftUI`, or `URLSession` — the package has no such dependencies so the compiler catches violations.
- Adapter files (`KeychainIdentityStore`, `DeposplitApiAdapter`, `LocalContactRepository`, `LocalShareRepository`, …): may import anything; add `import hexagon` to use domain types.

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
