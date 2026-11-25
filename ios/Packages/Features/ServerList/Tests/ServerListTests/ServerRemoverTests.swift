import AgentKit
import Foundation
import Persistence
import SwiftData
import Testing

@testable import ServerList

/// S1.4 acceptance: deleting a server revokes its token on the agent, then forgets it on the device.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ServerRemoverTests {
    let container: ModelContainer
    let secrets = InMemorySecretStore()
    let record = ServerRecord(name: "web", host: "web.example.com", sortOrder: 0)

    init() throws {
        container = try PulseStore.makeContainer(inMemory: true)
        container.mainContext.insert(record)
        for account in Self.accounts(record.id) {
            secrets.write(Data("secret".utf8), for: account)
        }
        try AppSettings.current(in: container.mainContext).lastSelectedServerId = record.id
        try container.mainContext.save()
    }

    static func accounts(_ id: UUID) -> [KeychainAccount] {
        [.token(id), .spki(id), .sshKey(id), .sshHostKey(id)]
    }

    private var remover: ServerRemover {
        ServerRemover(secrets: secrets, context: container.mainContext)
    }

    private func isForgotten() throws -> Bool {
        let records = try container.mainContext.fetch(FetchDescriptor<ServerRecord>())
        let selected = try AppSettings.current(in: container.mainContext).lastSelectedServerId
        return records.isEmpty && Self.accounts(record.id).allSatisfy { secrets.read($0) == nil } && selected == nil
    }

    @Test func revokesThenForgetsEverything() async throws {
        let client = SwitchableClient()
        let key = UUID()
        try await remover.remove(record.id, client: client, idempotencyKey: key)
        #expect(client.revokeKeys == [key])
        #expect(try isForgotten())
    }

    @Test(arguments: [AgentError.unreachable, .timeout, .server(._internal, requestId: "r")])
    func failedRevokeKeepsTheServer(error: AgentError) async throws {
        let client = SwitchableClient()
        client.failure = error
        await #expect(throws: error) {
            try await remover.remove(record.id, client: client, idempotencyKey: UUID())
        }
        #expect(try container.mainContext.fetch(FetchDescriptor<ServerRecord>()).count == 1)
        #expect(Self.accounts(record.id).allSatisfy { secrets.read($0) != nil })
    }

    @Test func retryReusesTheKeyOfTheIntent() async throws {
        let client = SwitchableClient()
        let key = UUID()
        client.failure = .timeout
        _ = try? await remover.remove(record.id, client: client, idempotencyKey: key)
        client.failure = nil
        try await remover.remove(record.id, client: client, idempotencyKey: key)
        #expect(client.revokeKeys == [key, key])
        #expect(try isForgotten())
    }

    @Test func forgetWithoutRevokeSkipsTheAgent() throws {
        try remover.forget(record.id)
        #expect(try isForgotten())
    }

    @Test func otherServersStay() async throws {
        let other = ServerRecord(name: "db", host: "db.example.com", sortOrder: 1)
        container.mainContext.insert(other)
        secrets.write(Data("t".utf8), for: .token(other.id))
        try await remover.remove(record.id, client: SwitchableClient(), idempotencyKey: UUID())
        #expect(try container.mainContext.fetch(FetchDescriptor<ServerRecord>()).map(\.id) == [other.id])
        #expect(secrets.read(.token(other.id)) != nil)
    }
}

/// S1.4 acceptance: the user's order of servers survives as `sortOrder`.
@MainActor @Suite struct ServerOrderTests {
    @Test(arguments: [
        // (from, to) as List.onMove passes them → expected names
        ([0], 3, ["b", "c", "a"]),
        ([2], 0, ["c", "a", "b"]),
        ([0, 1], 3, ["c", "a", "b"]),
        ([1], 1, ["a", "b", "c"]),
        // A destination past the paired servers (the demo row) lands at the end.
        ([0], 9, ["b", "c", "a"]),
    ])
    func moveRewritesSortOrder(source: [Int], destination: Int, expected: [String]) {
        // Gaps in sortOrder, as after deletions.
        let records = [("a", 0), ("b", 4), ("c", 7)].map { ServerRecord(name: $0.0, host: $0.0, sortOrder: $0.1) }
        ServerOrder.move(records.shuffled(), from: IndexSet(source), to: destination)
        let ordered = records.sorted { $0.sortOrder < $1.sortOrder }
        #expect(ordered.map(\.name) == expected)
        #expect(ordered.map(\.sortOrder) == [0, 1, 2])
    }
}
