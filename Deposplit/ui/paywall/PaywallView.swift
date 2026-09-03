import hexagon
import StoreKit
import SwiftUI

/// What Premium unlocks, and the two buttons that get it. No view model: `StoreKitPurchaseStore`
/// is already `@Observable` and holds everything this screen shows.
struct PaywallView: View {
    let store: StoreKitPurchaseStore

    var body: some View {
        Form {
            Section {
                Text("One purchase, once. No subscription, no ads.")
            }

            Section("As many secrets as you like") {
                Text("Free covers \(SecretLimits.freeTierMaxActiveSecrets) secrets at a time. Discarding one frees its slot straight away.")
            }

            Section("Bring your own relay") {
                Text("Point this device, or an individual contact, at a relay you run yourself. Accepting shares from someone else's relay stays free.")
            }

            Section {
                if store.isUnlocked {
                    Label("Premium is unlocked on this device.", systemImage: "checkmark.seal")
                } else {
                    Button {
                        Task { await store.purchase() }
                    } label: {
                        if let product = store.product {
                            // `verbatim:` because the price is data from the store, not copy.
                            Text(verbatim: "\(String(localized: "Unlock Premium")) — \(product.displayPrice)")
                        } else {
                            Text("Unlock Premium")
                        }
                    }
                    .disabled(store.product == nil || store.isPurchasing)
                    Button("Restore purchase") {
                        Task { await store.restore() }
                    }
                    .disabled(store.isPurchasing)
                    if store.product == nil {
                        Text("The App Store did not answer, so there is nothing to buy right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage = store.errorMessage {
                    // Already a finished sentence from StoreKit, so the plain-String overload.
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Whether Premium is unlocked is decided on this device. The relay never learns anything about it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Deposplit Premium")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
    }
}
