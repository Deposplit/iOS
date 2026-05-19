import SwiftUI

struct RecipientRequestsTab: View {
    @Bindable var viewModel: RequestsViewModel

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .overlay(alignment: .bottom) {
            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.red, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
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
                Text(request.share.label).font(.headline)
                Spacer()
                Text(request.requestType.label)
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
        request.requestType == .retrieve ? .blue : .orange
    }
}

private extension ShareRequestType {
    var label: LocalizedStringKey {
        switch self {
        case .retrieve: "Retrieve"
        case .delete: "Delete"
        }
    }
}
