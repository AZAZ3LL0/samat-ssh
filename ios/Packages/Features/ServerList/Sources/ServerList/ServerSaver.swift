import AgentKit
import Foundation
import Persistence
import SwiftData

/// How the app reaches a server over SSH after an install (docs/adr/0001). The password is not here.
struct SSHCredentials {
    let host: String
    let port: Int
    let user: String
    let key: SSHKeyPair
    let hostKey: SSHPublicKey
}

/// Stores a paired server: secrets in the Keychain, then its `ServerRecord`. Shared by every way to add one.
@MainActor struct ServerSaver {
    let secrets: any SecretStore
    let context: ModelContext

    /// Secrets first, record last: `AppEnvironment` reads secrets only for an existing record.
    /// - Parameter name: the name the user typed; empty falls back to the agent's hostname.
    func save(
        host: String, port: Int, name: String, probe: AgentProbe, token: PairResponse, ssh: SSHCredentials? = nil
    ) throws -> UUID {
        let existing = record(host: host, port: port)
        let id = existing?.id ?? UUID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.write(Data(probe.fingerprint.utf8), for: .spki(id))
            try secrets.write(Data(token.token.utf8), for: .token(id))
            if let ssh {
                try secrets.write(ssh.key.rawRepresentation, for: .sshKey(id))
                try secrets.write(Data(ssh.hostKey.openSSH.utf8), for: .sshHostKey(id))
            }
            let record: ServerRecord
            if let existing {
                record = existing
            } else {
                record = ServerRecord(id: id, name: "", host: host, port: port, sortOrder: try nextSortOrder())
            }
            record.name = trimmedName.isEmpty ? probe.info.hostname : trimmedName
            record.lastSeenAt = .now
            record.lastApiVersion = probe.info.apiVersion
            if let ssh {
                record.sshHost = ssh.host
                record.sshPort = ssh.port
                record.sshUser = ssh.user
            }
            if existing == nil { context.insert(record) }
            try context.save()
            return id
        } catch {
            // A re-paired server keeps the new secrets: the old token and pin no longer work anyway.
            if existing == nil {
                for account in [KeychainAccount.spki(id), .token(id), .sshKey(id), .sshHostKey(id)] {
                    try? secrets.delete(account)
                }
            }
            context.rollback()
            throw error
        }
    }

    func record(host: String, port: Int) -> ServerRecord? {
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.host == host && $0.port == port })
        return try? context.fetch(descriptor).first
    }

    /// The app's SSH key for a server installed earlier from this host, so a rerun appends no second key.
    func sshKey(sshHost: String, user: String) -> SSHKeyPair? {
        let descriptor = FetchDescriptor<ServerRecord>(
            predicate: #Predicate { $0.sshHost == sshHost && $0.sshUser == user })
        guard let record = try? context.fetch(descriptor).first,
            let raw = try? secrets.read(.sshKey(record.id))
        else { return nil }
        return try? SSHKeyPair(rawRepresentation: raw)
    }

    private func nextSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<ServerRecord>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try context.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }
}
