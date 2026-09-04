# CLAUDE.md — iOS

Guidance for Claude Code working in this repository. Platform-specific only; the shared
design is documented in the hub repository.

## Context, in ten lines

Deposplit splits a secret into *n* shares using Shamir's Secret Sharing, gives each to a
contact, and reconstructs it from any *k*. Fewer than *k* shares reveal nothing.

Identity is a keypair, not an account: an Ed25519 pair for authenticating to the relay and
an X25519 pair for encryption, both generated at first launch. Contacts exchange public keys
out of band — a QR code in person — never through a server. The relay stores and forwards
opaque ciphertext and cannot decrypt anything or learn who anybody is. Holders decrypt their
share at pickup and keep the **plaintext** locally, re-encrypting fresh to the requester's
*current* key at retrieval; that is what lets social recovery work after key loss. Retrieval
needs the holder's consent, which is the real protection — not the keypair.

Read before changing anything non-trivial:
[architecture](https://github.com/Deposplit/deposplit.com/blob/main/docs/architecture.md) ·
[protocol](https://github.com/Deposplit/deposplit.com/blob/main/docs/protocol.md) ·
[security](https://github.com/Deposplit/deposplit.com/blob/main/docs/security.md) ·
[trust model](https://github.com/Deposplit/deposplit.com/blob/main/docs/trust-model.md).
Open work is tracked in the hub's
[TODO.md](https://github.com/Deposplit/deposplit.com/blob/main/TODO.md).

## Toolchain

- Xcode 26+, Swift 6, `swift-tools-version: 6.0`
- Deployment target **iOS 26.4** (`IPHONEOS_DEPLOYMENT_TARGET`); the package also declares
  macOS 15.0 so the domain can be tested off-device. Do not lower either.
- **SwiftUI only.** No storyboards, and no UIKit beyond a `UIViewControllerRepresentable`
  where there is genuinely no SwiftUI equivalent.
- **Swift Testing** (`@Test`), not XCTest.

## The boundary, enforced by the compiler

| Path | May import |
|---|---|
| `hexagon/Sources/…` | `Foundation` and `CryptoKit` — **nothing else** |
| `Deposplit/…` | Anything; add `import hexagon` to use domain types |

`hexagon/Package.swift` declares **no external dependencies**, and in particular no
`Security`, `UIKit`, `SwiftUI` or `URLSession`. That is what makes an accidental import a
build error instead of a slow erosion. If domain code seems to need one of those, the logic
belongs in an adapter in `Deposplit/` instead.

The app target uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+): **any `.swift` file
placed under `Deposplit/` is compiled automatically.** Adding an adapter or a view needs no
`project.pbxproj` edit.

## Platform decisions worth preserving

- **Private keys live in the Keychain**, not the Secure Enclave. The Enclave only handles
  P256, and Deposplit needs Curve25519 — so software Keychain it is:
  `kSecClassGenericPassword`, service `com.deposplit.Deposplit`, accessibility
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- **Account strings**: `verify.public`, `enc.public`, `sign.private`, `dec.private`, plus
  `dec.private.previous` — the key-agreement key displaced by the last rotation, kept one
  generation so a share sealed before the rotation can still be opened at pickup. The
  pseudonym and the `registered` flag live in `UserDefaults`, not the Keychain.
- **Share encryption uses CryptoKit**: X25519 key agreement →
  `sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: "deposplit-share", outputByteCount: 32)`
  → `ChaChaPoly.seal(plaintext, using: key, nonce: nonce)`.
- **Ciphertext wire format is `suiteTag(1) || nonce(12) || ciphertext+tag`** — that is
  `sealedBox.combined` with the one-byte suite tag prefixed. The leading tag is easy to
  forget when hand-checking bytes.
- **Request signing**: `CryptoKit.SHA256.hash(data:)` for the body hash, `key.signature(for:)`
  for Ed25519.
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is set in build settings, so all types are
  `@MainActor` by default. Async network calls suspend rather than block, and the CPU-bound
  work here (QR generation, secret sharing) is fast enough to stay on the main actor.
- **`@Observable`**, not `ObservableObject`/`@Published`, for every view model.
- **`NavigationStack`**, not the deprecated `NavigationView`.
- QR scanning uses **`DataScannerViewController`** (VisionKit). Its representable wrapper is
  deliberately `internal` rather than `private`. QR generation uses CoreImage and is
  synchronous and MainActor-safe.
- Catalog backup uses SwiftUI's **`.fileExporter` / `ShareLink` / `.fileImporter`** — the
  counterpart to Android's Storage Access Framework.

> **Swift structs have no `copy()`, and this has already caused two silent-data-loss bugs.**
> `Contact` is reconstructed through its memberwise initialiser in `ContactService`
> (`updateContact`, `markKeyCompromised`) and at every heartbeat-mutation site in
> `ShareService`. **Every new field must be threaded through all of them by hand**, or it is
> silently reset the next time a contact is touched. Kotlin's and Scala's `copy()` carry
> unlisted fields forward automatically; Swift does not. When adding a field to `Contact`,
> grep for every `Contact(` construction site before assuming you are done.

## Biometrics

`ui/biometric/BiometricGate.swift` is pure `Foundation` + `LocalAuthentication`, with no
SwiftUI import. It uses the Swift-concurrency-native
`evaluatePolicy(_:localizedReason:) async throws -> Bool` overload directly — no
completion-handler bridging. `LAContext.canEvaluatePolicy` needs no host view or activity
reference, unlike Android's `BiometricManager.from(context)`, so nothing here depends on the
calling view.

`INFOPLIST_KEY_NSFaceIDUsageDescription` is set in **both** build configurations. Face ID
requires an Info.plist usage description; Touch ID does not.

**There is deliberately no `SKIP_BIOMETRIC`-equivalent build flag**, unlike Android. The
Simulator has first-class enrolment simulation — Features → Face ID → Enrolled, then
Matching/Non-matching Face — which covers the same "test without biometric hardware" need
with no bypass in app code. A Simulator without enrolment shows the same unavailable state a
real device would.

## Purchases

The freemium unlock is one non-consumable, `com.deposplit.premium`. `StoreKitPurchaseStore`
owns products, purchase and restore; `UserDefaultsPurchaseRepository` is the cache it writes
through, and the cache is what the hexagon's `PurchaseRepository` port reads — synchronously,
so the domain needs neither `async` nor the network to know what this device owns.

**StoreKit Testing in Xcode is the Simulator-native equivalent of the Face ID enrolment
simulation above**, so iOS needs no fake-Premium build flag (Android does, because Google
Play Billing has no offline mode at all). `Deposplit.storekit` at the repository root defines
the product locally and is attached to the shared scheme as a
`StoreKitConfigurationFileReference`, so **no App Store Connect record is required**: the
unlock can be bought for real in the Simulator, and Debug → StoreKit → Manage Transactions
deletes the transaction again to get back to the locked state. Local testing needs no In-App
Purchase entitlement either.

The App Store **Sandbox** — a sandbox Apple ID against Apple's servers — is a different
thing, and does need a device and an App Store Connect record. That is a pre-ship rehearsal,
not a development dependency.

## Build and test

```bash
# from hexagon/ — no simulator needed, this is what CI runs
swift build
swift test                                  # 144 tests
swift test --filter ShareServiceTests

# from the repo root — the app target
xcodebuild build -project Deposplit.xcodeproj -scheme Deposplit \
  -destination 'generic/platform=iOS'

xcodebuild test -project Deposplit.xcodeproj -scheme Deposplit \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

All tests live in `hexagon/Tests/` — a flat directory, eight files. **There is no
app-target test directory**; do not go looking for one.

> `xcodebuild test` fails on the development machine with a code-signing error on an
> unsigned `DeposplitTests.xctest` dylib. This is a machine-level issue unrelated to app
> code: `xcodebuild build` passes clean, and the domain is covered by the hexagon suite.

> **On Windows there may be no Swift toolchain at all.** Check with `Get-Command swift`
> before assuming iOS changes can be verified locally — a previous note claiming Swift was
> installed went stale. When it is unavailable, iOS changes can still be written correctly
> by mirroring the already-verified Kotlin or Scala implementation line for line, but must
> be **flagged as unverified** and handed off for a real `swift build` / `swift test` run on
> a Mac. Do not report such a change as tested.

Manual end-to-end flows are in the hub's
[testing.md](https://github.com/Deposplit/deposplit.com/blob/main/docs/testing.md).

## Localisation

German and English in `Deposplit/Localizable.xcstrings`. Xcode auto-extracts strings but
leaves the `"de"` `stringUnit` empty, so new strings need filling in by hand. Established
terminology: *Abrufanfrage* (retrieval request), *Inhaber* (holder), *Bestand* (inventory),
informal *du*. Plurals use `variations.plural` with `one` and `other`.

> **Watch for the `String` vs `LocalizedStringKey` trap.** A view that takes `title: String`
> and passes it to `Text` silently defeats localisation — the string is interpolated rather
> than looked up, so it stays in English with no warning. This has bitten twice. When adding
> a view that displays caller-supplied text, take `LocalizedStringKey`.

## House style

- Match the surrounding code. Value objects are `struct`s, usually `Codable` — which is why
  the local repositories can persist domain types directly, unlike Android's hand-written
  catalog codec.
- Ports are `protocol`s named for the capability, not the implementation.
- Line endings are CRLF; `core.autocrlf` handles conversion, so do not hand-convert.
- Do not reference work items by number in comments. Say what the code does and why.
- Changes to shared concepts — ports, value objects, canonical byte constructions — should
  land on Android and the relay too. `PayloadCanonical` in particular is **append-only**, and
  its cross-platform vector tests must be updated in lockstep. Note that CryptoKit produces
  *hedged* (non-deterministic) signatures, so iOS vector tests assert canonical-byte equality
  and verification against a fixed signature, rather than reproducing the signature bytes.
