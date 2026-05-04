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
├── Deposplit.xcodeproj/
├── Deposplit/                        ← app target sources (PBXFileSystemSynchronizedRootGroup — all .swift files are compiled automatically)
│   ├── DeposplitApp.swift            @main entry point + RootView (routes to SignInView or HomeView)
│   ├── ShamirSecretSharing.swift     SSS library (part of app target)
│   ├── auth/
│   │   ├── AuthPort.swift            Driving port protocol
│   │   ├── AuthError.swift           Shared error enum
│   │   ├── IdentityStore.swift       Driven port protocol (key/pseudonym storage)
│   │   ├── AuthService.swift         AuthPort implementation — CryptoKit only, no Security/UserDefaults
│   │   ├── KeychainIdentityStore.swift  IdentityStore adapter — Security framework + UserDefaults
│   │   └── SignInViewModel.swift
│   ├── api/
│   │   ├── ShareTransport.swift      Domain port protocol + value types (Role, ShareRequestType, ShareRequestState, ShareMetadata, ShareRequest)
│   │   └── DeposplitApiAdapter.swift  HTTP adapter: URLSession + Ed25519 request signing + SHA-256 body hash
│   │                                  pickUpShare (GET /shares/:shareId) + ciphertext-on-approve (PATCH /share-requests/:id)
│   ├── contacts/
│   │   ├── Contact.swift             Contact + VerificationLevel + ContactRepository protocol
│   │   └── LocalContactRepository.swift  JSON file in Documents/ folder
│   ├── shares/
│   │   ├── HeldShare.swift           HeldShare value type + ShareRepository protocol (local share storage)
│   │   └── LocalShareRepository.swift  JSON file in Documents/shares.json; ciphertext standard base64, senderKey base64url
│   └── ui/
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
- **No separate hexagon target** — unlike Android (which has a `:hexagon` Gradle module), all Swift code is in the single `Deposplit` app target. Domain protocols (`AuthPort`, `ShareTransport`, `ContactRepository`) enforce the Ports & Adapters boundary by convention, not by the build system. The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+): any `.swift` file placed in `Deposplit/` is automatically compiled — no need to edit `project.pbxproj` when adding source files.

## Boundary rule (enforced by convention, not build system)

- Domain files (`AuthPort`, `IdentityStore`, `AuthService`, `ShamirSecretSharing`, `ShareTransport`, `Contact`, `HeldShare`, …): may import `CryptoKit` and `Foundation`; must NOT import `Security`, `UIKit`, `SwiftUI`, or `URLSession`.
- Adapter files (`KeychainIdentityStore`, `DeposplitApiAdapter`, `LocalContactRepository`, `LocalShareRepository`, …): may import anything.
