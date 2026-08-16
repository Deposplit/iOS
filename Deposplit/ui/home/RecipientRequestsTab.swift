import hexagon
import SwiftUI

struct RecipientRequestsTab: View {
    @Bindable var viewModel: RequestsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(error)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") { Task { await viewModel.load() } }
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
                Divider()
            }
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.error != nil && viewModel.pendingRequests.isEmpty {
                Spacer()
            } else if viewModel.pendingRequests.isEmpty {
                ContentUnavailableView("No pending requests", systemImage: "checkmark.circle")
            } else {
                List(viewModel.pendingRequests) { request in
                    RequestCard(
                        request: request,
                        senderName: viewModel.senderName(for: request),
                        isResponding: viewModel.respondingTo == request.id,
                        onApprove: { Task { await viewModel.respond(to: request, approve: true) } },
                        onDeny: { Task { await viewModel.respond(to: request, approve: false) } }
                    )
                }
            }
        }
    }
}

private struct RequestCard: View {
    let request: ShareRequest
    let senderName: String
    let isResponding: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.label).font(.headline)
                Spacer()
                Text(request.transactionType.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Text("From: \(senderName)").font(.caption).foregroundStyle(.secondary)

            HStack {
                if isResponding {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Button("Deny", role: .destructive, action: onDeny)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeColor: Color {
        request.transactionType == .retrieval ? .blue : .orange
    }
}

private extension ShareTransactionType {
    var label: LocalizedStringKey {
        switch self {
        case .deposit: "Deposit"
        case .retrieval: "Retrieval"
        case .removal: "Removal"
        // Never surfaced here — inventory is a self-approved push, consumed silently by
        // syncInbox's processRecoveryMetadata, not routed through listPendingRequests.
        case .inventory: "Inventory"
        }
    }
}
