import AgentKit
import Foundation
import Persistence
import SwiftData

/// Deletes a paired server: its token on the agent first, then everything the device keeps about it.
@MainActor public struct ServerRemover {
    let secrets: any SecretStore
    let context: ModelContext

    public init(secrets: any SecretStore, context: ModelContext) {
        self.secrets = secrets
        self.context = context
    }

    /// Revokes the token, then forgets the server. A failed revoke keeps everything, so the user can
    /// retry with the same `idempotencyKey` or choose `forget` knowing the token stays valid.
    public func remove(_ id: UUID, client: any AgentClient, idempotencyKey: UUID) async throws {
        try await client.revokeOwnToken(idempotencyKey: idempotencyKey)
        try forget(id)
    }

    /// Forgets the server without asking the agent. Its token stays valid until revoked
    /// from another device or with `pulse-agent tokens revoke`.
    public func forget(_ id: UUID) throws {
        for account in [KeychainAccount.token(id), .spki(id), .sshKey(id), .sshHostKey(id)] {
            try secrets.delete(account)
        }
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        let settings = try AppSettings.current(in: context)
        if settings.lastSelectedServerId == id { settings.lastSelectedServerId = nil }
        try context.save()
    }
}

/// The user's order of servers, kept in `ServerRecord.sortOrder`.
public enum ServerOrder {
    /// Applies a `List.onMove` to the paired servers and renumbers them `0..<n`.
    /// A destination past them (the demo row comes last) means the end.
    @MainActor public static func move(_ records: [ServerRecord], from source: IndexSet, to destination: Int) {
        var ordered = records.sorted { $0.sortOrder < $1.sortOrder }
        ordered.move(fromOffsets: source, toOffset: min(destination, ordered.count))
        for (index, record) in ordered.enumerated() {
            record.sortOrder = index
        }
    }
}
