import Foundation
import Testing

@testable import AgentKit

@Suite(.timeLimit(.minutes(1))) struct FakeAgentClientTests {
    @Test func servesInfoAndMetricsFromFixtures() async throws {
        let client = FakeAgentClient()
        let info = try await client.info()
        #expect(info.apiVersion == AgentCompatibility.clientApiVersion)
        try AgentCompatibility.check(info)

        let metrics = try await client.hostMetrics()
        #expect((0...1).contains(metrics.cpu.usageRatio))
        #expect(metrics.memory.usedBytes + metrics.memory.availableBytes == metrics.memory.totalBytes)
    }

    @Test func streamsEveryFixtureWithIncreasingSeq() async throws {
        let client = FakeAgentClient(interval: .milliseconds(1))
        var events: [WsEvent<HostMetrics>] = []
        for try await event in client.subscribe(.metricsHost).prefix(7) {
            events.append(event)
        }
        #expect(events.map(\.seq) == Array(1...7))
        // Five fixtures replay in a loop.
        #expect(events[5].payload == events[0].payload)
        #expect(events[0].payload != events[1].payload)
    }

    @Test(arguments: [
        AgentError.unreachable, .timeout, .unauthorized, .pinMismatch, .server(._internal, requestId: "r"),
    ])
    func failingModeFailsEveryCall(error: AgentError) async {
        let client = FakeAgentClient(mode: .failing(error))
        await #expect(throws: error) { try await client.info() }
        await #expect(throws: error) { try await client.hostMetrics() }
        await #expect(throws: error) {
            for try await _ in client.subscribe(.metricsHost) {}
        }
    }

    @Test func dropWebSocketEndsStreamAfterEvents() async {
        let client = FakeAgentClient(mode: .dropWebSocket(after: 3), interval: .milliseconds(1))
        var seqs: [Int64] = []
        await #expect(throws: AgentError.unreachable) {
            for try await event in client.subscribe(.metricsHost) {
                seqs.append(event.seq)
            }
        }
        #expect(seqs == [1, 2, 3])
    }

    @Test func slowModeDelaysResponses() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { _ = try await FakeAgentClient(mode: .slow).info() }
        #expect(elapsed >= FakeAgentClient.slowDelay)
    }

    @Test func knowsExactlyTheContractTopics() throws {
        let spec = URL(filePath: #filePath).appending(path: "../../../../../../api/openapi.yaml").standardized
        let yaml = try String(contentsOf: spec, encoding: .utf8)
        let topics = yaml.matches(of: /\n  - topic: (\S+)/).map { String($0.1) }
        #expect(!topics.isEmpty)
        #expect(Set(topics) == FakeAgentClient.contractTopics)
    }
}
