import hexagon
import SwiftUI

/// A one-line advisory summarizing the reconstruction integrity cross-check, shown wherever a
/// reconstructed secret is displayed (`ShareDetailView`, `RepairView`).
struct ReconstructionAdvisoryView: View {
    let integrity: ReconstructionIntegrity
    let contactName: (UUID) -> String

    var body: some View {
        switch integrity {
        case .noMargin:
            Label("Reconstructed from exactly the required shares — no integrity cross-check was possible.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .confirmed:
            Label("Integrity confirmed — every collected share agreed.", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
        case .excludedSuspects(let excludedContactIds):
            let names = excludedContactIds.map(contactName).sorted().joined(separator: ", ")
            Label("Excluded \(excludedContactIds.count) inconsistent share(s) (from: \(names)). Reconstructed from the remaining consistent shares.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
