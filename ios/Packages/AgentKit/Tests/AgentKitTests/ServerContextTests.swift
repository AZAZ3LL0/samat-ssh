import AgentAPI
import Foundation
import Testing

@testable import AgentKit

/// Answers `info()` with a fixed agent; nothing else is reachable through it.
private struct InfoClient: AgentClient {
    let info: AgentInfo

    func info() async throws(AgentError) -> AgentInfo { info }

    func hostMetrics() async throws(AgentError) -> HostMetrics { throw .unreachable }

    func subscribe<T: Decodable & Sendable>(_ topic: WsTopic<T>) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.unreachable) }
    }
}

@MainActor @Suite struct ServerContextTests {
    @Test func startsConnecting() {
        let context = ServerContext(serverId: UUID(), client: FakeAgentClient())
        #expect(context.connection == .connecting)
        #expect(context.info == nil)
    }

    @Test func connectsToDemoAgent() async {
        let context = ServerContext(serverId: UUID(), client: FakeAgentClient())
        await context.connect()
        #expect(context.connection == .connected)
        #expect(context.error == nil)
        #expect(context.info?.hostname == "demo")
        #expect(context.supports(.hostMetrics))
        #expect(!context.supports(.projects))
    }

    @Test(arguments: [AgentError.unreachable, .timeout, .unauthorized, .pinMismatch])
    func goesOfflineWithTheError(error: AgentError) async {
        let context = ServerContext(serverId: UUID(), client: FakeAgentClient(mode: .failing(error)))
        await context.connect()
        #expect(context.connection == .offline)
        #expect(context.error == error)
        #expect(!context.supports(.hostMetrics))
    }

    @Test func rejectsAgentOlderThanTheApp() async {
        let old = AgentInfo(
            agentVersion: "0.0.1",
            apiVersion: 1,
            minClientApiVersion: 1,
            hostname: "old",
            features: [.hostMetrics]
        )
        let context = ServerContext(serverId: UUID(), client: InfoClient(info: old))
        await context.connect()
        #expect(context.connection == .offline)
        #expect(context.error == .incompatibleAgent(agent: 1, required: AgentCompatibility.clientApiVersion))
        #expect(context.info?.hostname == "old")
    }

    @Test func clearsTheErrorOnReconnect() async {
        let context = ServerContext(serverId: UUID(), client: FakeAgentClient())
        await context.connect()
        await context.connect()
        #expect(context.error == nil)
        #expect(context.connection == .connected)
    }
}
