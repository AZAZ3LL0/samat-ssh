import AgentKit
import SwiftUI

/// One intent to delete a server. The idempotency key lives as long as the intent, so a retry
/// after a timeout cannot count as a second revoke.
struct ServerDeletion: Identifiable {
    let entry: ServerEntry
    let idempotencyKey = UUID()
    var id: UUID { entry.id }
}

extension View {
    /// Confirm → revoke the token on the agent → forget the server. When the agent cannot revoke,
    /// the user retries or deletes locally, told that the token stays valid.
    func serverDeletion(
        _ deletion: Binding<ServerDeletion?>, environment: AppEnvironment, onDeleted: @escaping (UUID) -> Void
    ) -> some View {
        modifier(ServerDeletionModifier(deletion: deletion, environment: environment, onDeleted: onDeleted))
    }
}

private struct ServerDeletionModifier: ViewModifier {
    @Binding var deletion: ServerDeletion?
    let environment: AppEnvironment
    let onDeleted: (UUID) -> Void
    @State private var confirming = false
    @State private var failure: AgentError?
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .onChange(of: deletion?.id) { _, id in
                confirming = id != nil
                failure = nil
            }
            .overlay {
                if busy { ProgressView().controlSize(.large) }
            }
            .confirmationDialog(
                String(localized: "Delete \(deletion?.entry.name ?? "")?"), isPresented: $confirming,
                titleVisibility: .visible, presenting: deletion
            ) { request in
                Button(String(localized: "Delete"), role: .destructive) { Task { await remove(request) } }
                Button(String(localized: "Cancel"), role: .cancel) { deletion = nil }
            } message: { _ in
                Text("The app revokes its token on the server and forgets the server on this device.")
            }
            .alert(
                String(localized: "The server did not revoke the token"),
                isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                presenting: deletion
            ) { request in
                Button(String(localized: "Try again")) { Task { await remove(request) } }
                Button(String(localized: "Delete on this device only"), role: .destructive) { forget(request) }
                Button(String(localized: "Cancel"), role: .cancel) { deletion = nil }
            } message: { _ in
                Text(
                    "The token stays valid until you revoke it from another device or with pulse-agent tokens revoke."
                )
            }
    }

    private func remove(_ request: ServerDeletion) async {
        busy = true
        defer { busy = false }
        do {
            let client = environment.makeClient(for: request.entry)
            try await environment.makeRemover().remove(
                request.id, client: client, idempotencyKey: request.idempotencyKey)
            finish(request)
        } catch let error as AgentError {
            failure = error
        } catch {
            // Only the Keychain or the store can fail here; the agent already revoked the token.
            failure = nil
            forget(request)
        }
    }

    private func forget(_ request: ServerDeletion) {
        try? environment.makeRemover().forget(request.id)
        finish(request)
    }

    private func finish(_ request: ServerDeletion) {
        onDeleted(request.id)
        deletion = nil
    }
}
