import AgentKit
import Foundation
import Persistence
import SwiftData
import Testing

@testable import ServerList

/// S1.4 acceptance: each server in the list shows online or offline and a short CPU trend.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ServerStatusModelTests {
    let container: ModelContainer

    init() throws {
        container = try PulseStore.makeContainer(inMemory: true)
    }

    private func model(_ clients: [UUID: any AgentClient]) -> ServerStatusModel {
        ServerStatusModel(context: container.mainContext) { id in clients[id] ?? FakeAgentClient() }
    }

    @Test func unknownServerIsConnectingWithNoTrend() {
        let status = model([:]).status(for: UUID())
        #expect(status.connection == .connecting)
        #expect(status.cpu.isEmpty)
    }

    @Test func answeringServerIsOnlineWithItsCpu() async throws {
        let id = UUID()
        let model = model([id: FakeAgentClient()])
        await model.refresh([id])
        let status = model.status(for: id)
        #expect(status.connection == .connected)
        let expected = try await FakeAgentClient().hostMetrics().cpu.usageRatio
        #expect(status.cpu == [expected])
    }

    @Test(arguments: [AgentError.unreachable, .timeout, .unauthorized, .pinMismatch])
    func failingServerIsOfflineAndKeepsItsTrend(error: AgentError) async {
        let id = UUID()
        let client = SwitchableClient()
        let model = model([id: client])
        await model.refresh([id])
        client.failure = error
        await model.refresh([id])
        #expect(model.status(for: id).connection == .offline)
        // The last known trend stays visible next to the offline mark.
        #expect(model.status(for: id).cpu.count == 1)
    }

    @Test func trendKeepsOnlyTheNewestValues() async {
        let id = UUID()
        let model = model([id: FakeAgentClient()])
        for _ in 0..<(ServerStatusModel.trendLength + 5) {
            await model.refresh([id])
        }
        #expect(model.status(for: id).cpu.count == ServerStatusModel.trendLength)
    }

    @Test func answerRecordsLastSeen() async throws {
        let record = ServerRecord(name: "web", host: "web.example.com", sortOrder: 0)
        container.mainContext.insert(record)
        let model = model([record.id: FakeAgentClient()])
        await model.refresh([record.id])
        let seen = try #require(record.lastSeenAt)
        #expect(abs(seen.timeIntervalSinceNow) < 5)
    }

    @Test func serversAreIndependent() async {
        let (online, offline) = (UUID(), UUID())
        let model = model([online: FakeAgentClient(), offline: FakeAgentClient(mode: .failing(.unreachable))])
        await model.refresh([online, offline])
        #expect(model.status(for: online).connection == .connected)
        #expect(model.status(for: offline).connection == .offline)
    }
}

/// Answers like the demo agent until `failure` is set.
final class SwitchableClient: AgentClient, @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var _failure: AgentError?
    private var _revokeKeys: [UUID] = []
    private let healthy = FakeAgentClient()

    var failure: AgentError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    /// Idempotency keys of every revoke call, failed ones included.
    var revokeKeys: [UUID] { lock.withLock { _revokeKeys } }

    func info() async throws(AgentError) -> AgentInfo {
        if let failure { throw failure }
        return try await healthy.info()
    }

    func hostMetrics() async throws(AgentError) -> HostMetrics {
        if let failure { throw failure }
        return try await healthy.hostMetrics()
    }

    func pair(code: String, deviceName: String) async throws(AgentError) -> PairResponse {
        try await healthy.pair(code: code, deviceName: deviceName)
    }

    func revokeOwnToken(idempotencyKey: UUID) async throws(AgentError) {
        lock.withLock { _revokeKeys.append(idempotencyKey) }
        if let failure { throw failure }
    }

    func subscribe<T: Decodable & Sendable>(_ topic: WsTopic<T>) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        healthy.subscribe(topic)
    }
}
