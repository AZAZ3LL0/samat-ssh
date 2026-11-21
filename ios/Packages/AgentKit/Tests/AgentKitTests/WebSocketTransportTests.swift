import Fixtures
import Foundation
import Testing
import os

@testable import AgentKit

@Suite(.timeLimit(.minutes(1))) struct WebSocketTransportTests {
    private let connector = ScriptedConnector()
    private let fast = Backoff(initial: .milliseconds(1), maximum: .milliseconds(5), jitter: 0)

    /// The scripted agent stays silent between steps, and a starved CI runner can stretch
    /// that past the real 45 s idle timeout; only the idle test sets a short one.
    private func transport(idleTimeout: Duration = .seconds(3600)) -> WebSocketTransport {
        WebSocketTransport(connector: connector, backoff: fast, idleTimeout: idleTimeout, random: { 0 })
    }

    @Test func subscribesAndDeliversTypedEvents() async throws {
        var events = transport().subscribe(.metricsHost).makeAsyncIterator()
        let socket = await connector.next()
        let requestId = try await socket.expectSubscribe("metrics.host")

        await socket.push(.subscribed(requestId))
        await socket.push(.event("metrics.host", seq: 1))
        let event = try #require(try await events.next())
        #expect(event.seq == 1)
        #expect(event.payload.cpu.cores == 4)
    }

    @Test func answersPingWithPong() async throws {
        let stream = transport().subscribe(.metricsHost)
        let socket = await connector.next()
        _ = try await socket.expectSubscribe("metrics.host")
        await socket.push(.ping)
        #expect(try await socket.nextSent().type == "pong")
        _ = stream
    }

    /// Skeleton checklist: the client reconnects and resubscribes after a drop.
    @Test func reconnectsAndResubscribesAfterDrop() async throws {
        var events = transport().subscribe(.metricsHost).makeAsyncIterator()
        let first = await connector.next()
        let firstId = try await first.expectSubscribe("metrics.host")
        await first.push(.subscribed(firstId))
        await first.push(.event("metrics.host", seq: 1))
        #expect(try await events.next()?.seq == 1)

        await first.drop(.unreachable)
        let second = await connector.next()
        let secondId = try await second.expectSubscribe("metrics.host")
        #expect(secondId != firstId)
        await second.push(.subscribed(secondId))
        await second.push(.event("metrics.host", seq: 1))
        #expect(try await events.next()?.seq == 1)
    }

    @Test(arguments: [AgentError.unauthorized, .pinMismatch])
    func stopsWithoutRetryWhenConnectCannotSucceed(error: AgentError) async throws {
        connector.failNext(with: error)
        let stream = transport().subscribe(.metricsHost)
        await #expect(throws: error) {
            for try await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(connector.attempts == 1)
    }

    @Test func stopsWithoutRetryOnUnauthorizedUpgrade() async throws {
        let stream = transport().subscribe(.metricsHost)
        let socket = await connector.next()
        _ = try await socket.expectSubscribe("metrics.host")
        await socket.drop(.unauthorized)
        await #expect(throws: AgentError.unauthorized) {
            for try await _ in stream {}
        }
        #expect(connector.attempts == 1)
    }

    @Test func resubscribesWhenSeqSkips() async throws {
        var events = transport().subscribe(.metricsHost).makeAsyncIterator()
        let socket = await connector.next()
        let firstId = try await socket.expectSubscribe("metrics.host")
        await socket.push(.subscribed(firstId))
        await socket.push(.event("metrics.host", seq: 1))
        await socket.push(.event("metrics.host", seq: 3))
        #expect(try await events.next()?.seq == 1)
        #expect(try await events.next()?.seq == 3)

        let unsubscribe = try await socket.nextSent()
        #expect(unsubscribe.type == "unsubscribe")
        #expect(unsubscribe.requestId == firstId)
        let secondId = try await socket.expectSubscribe("metrics.host")
        #expect(secondId != firstId)

        // Left over from the cancelled subscription, before the agent confirms the new one.
        await socket.push(.event("metrics.host", seq: 4))
        await socket.push(.subscribed(secondId))
        await socket.push(.event("metrics.host", seq: 1))
        #expect(try await events.next()?.seq == 1)
    }

    @Test func gapContinuesTheSequence() async throws {
        var events = transport().subscribe(.metricsHost).makeAsyncIterator()
        let socket = await connector.next()
        let requestId = try await socket.expectSubscribe("metrics.host")
        await socket.push(.subscribed(requestId))
        await socket.push(.event("metrics.host", seq: 1))
        await socket.push(.gap("metrics.host", seq: 5))
        await socket.push(.event("metrics.host", seq: 6))
        #expect(try await events.next()?.seq == 1)
        #expect(try await events.next()?.seq == 6)

        await socket.push(.ping)
        #expect(try await socket.nextSent().type == "pong", "no resubscribe after a gap")
    }

    @Test func errorForRequestFinishesItsStream() async throws {
        let stream = transport().subscribe(.metricsHost)
        let socket = await connector.next()
        let requestId = try await socket.expectSubscribe("metrics.host")
        await socket.push(.error(code: "invalid_request", requestId: "http-9", wsRequestId: requestId))
        await #expect(throws: AgentError.server(.invalidRequest, requestId: "http-9")) {
            for try await _ in stream {}
        }
    }

    @Test func reconnectsWhenAgentGoesSilent() async throws {
        let stream = transport(idleTimeout: .milliseconds(100)).subscribe(.metricsHost)
        let first = await connector.next()
        _ = try await first.expectSubscribe("metrics.host")
        let second = await connector.next()
        _ = try await second.expectSubscribe("metrics.host")
        #expect(first.isClosed)
        _ = stream
    }

    @Test func sharesOneSubscriptionPerTopicAndClosesWithLastConsumer() async throws {
        let transport = transport()
        let echo = WsTopic<Int>(name: "debug.echo")
        let metrics = Task { for try await _ in transport.subscribe(.metricsHost) {} }
        let socket = await connector.next()
        let metricsId = try await socket.expectSubscribe("metrics.host")

        let echoA = Task { for try await _ in transport.subscribe(echo) {} }
        let echoId = try await socket.expectSubscribe("debug.echo")
        let echoB = Task { for try await _ in transport.subscribe(echo) {} }
        try await Task.sleep(for: .milliseconds(50))
        await socket.push(.ping)
        #expect(try await socket.nextSent().type == "pong", "second consumer reuses the subscription")

        echoA.cancel()
        echoB.cancel()
        let unsubscribe = try await socket.nextSent()
        #expect(unsubscribe.type == "unsubscribe")
        #expect(unsubscribe.requestId == echoId)
        #expect(!socket.isClosed)

        metrics.cancel()
        try await eventually { socket.isClosed }
        #expect(metricsId != echoId)
    }
}

// MARK: - Test doubles

/// Hands out scripted sockets and records how often the transport connects.
final class ScriptedConnector: WebSocketConnector {
    private let state = OSAllocatedUnfairLock(initialState: (attempts: 0, failures: [AgentError]()))
    private let sockets = Mailbox<FakeSocket>()

    var attempts: Int { state.withLock { $0.attempts } }

    func failNext(with error: AgentError) {
        state.withLock { $0.failures.append(error) }
    }

    func next() async -> FakeSocket {
        guard case .success(let socket) = await sockets.next() else { fatalError("connector mailbox closed") }
        return socket
    }

    func connect() async throws(AgentError) -> any WebSocketConnection {
        let failure = state.withLock { state -> AgentError? in
            state.attempts += 1
            return state.failures.isEmpty ? nil : state.failures.removeFirst()
        }
        if let failure { throw failure }
        let socket = FakeSocket()
        await sockets.put(.success(socket))
        return socket
    }
}

final class FakeSocket: WebSocketConnection {
    struct Sent {
        let type: String
        let topic: String?
        let requestId: String?
    }

    private let inbox = Mailbox<String>()
    private let outbox = Mailbox<String>()
    private let closed = OSAllocatedUnfairLock(initialState: false)

    var isClosed: Bool { closed.withLock { $0 } }

    func send(_ text: String) async throws(AgentError) {
        await outbox.put(.success(text))
    }

    func receive() async throws(AgentError) -> String {
        try await inbox.next().get()
    }

    func close() {
        closed.withLock { $0 = true }
        // Closing the outbox too fails a test still waiting on this socket instead of
        // hanging it until the suite's time limit; messages sent before stay readable.
        Task {
            await inbox.close(.unreachable)
            await outbox.close(.unreachable)
        }
    }

    func push(_ message: AgentMessage) async {
        await inbox.put(.success(message.json))
    }

    func drop(_ error: AgentError) async {
        await inbox.close(error)
    }

    func nextSent() async throws -> Sent {
        let text = try await outbox.next().get()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let payload = object["payload"] as? [String: Any]
        return Sent(
            type: try #require(object["type"] as? String),
            topic: object["topic"] as? String,
            requestId: payload?["requestId"] as? String
        )
    }

    func expectSubscribe(_ topic: String) async throws -> String {
        let sent = try await nextSent()
        #expect(sent.type == "subscribe")
        #expect(sent.topic == topic)
        return try #require(sent.requestId)
    }
}

/// Messages the agent sends, as JSON text.
enum AgentMessage {
    case ping
    case subscribed(String)
    case event(String, seq: Int)
    case gap(String, seq: Int)
    case error(code: String, requestId: String, wsRequestId: String)

    var json: String {
        let time = #""ts":"2026-11-15T10:00:00.000Z""#
        switch self {
        case .ping:
            return #"{"type":"ping",\#(time)}"#
        case .subscribed(let id):
            return #"{"type":"subscribed","topic":"metrics.host",\#(time),"payload":{"requestId":"\#(id)"}}"#
        case .event(let topic, let seq):
            let fixture = try? Fixtures.data("host_metrics/01.json")
            let payload = fixture.flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
            return #"{"type":"event","topic":"\#(topic)","seq":\#(seq),\#(time),"payload":\#(payload)}"#
        case .gap(let topic, let seq):
            return #"{"type":"gap","topic":"\#(topic)","seq":\#(seq),\#(time),"payload":{"dropped":3}}"#
        case .error(let code, let requestId, let wsRequestId):
            let details = #"{"requestId":"\#(wsRequestId)"}"#
            let payload = #"{"code":"\#(code)","message":"m","requestId":"\#(requestId)","details":\#(details)}"#
            return #"{"type":"error",\#(time),"payload":\#(payload)}"#
        }
    }
}

/// A FIFO that suspends readers until a value or the close arrives.
actor Mailbox<Value: Sendable> {
    private var items: [Result<Value, AgentError>] = []
    private var waiters: [CheckedContinuation<Result<Value, AgentError>, Never>] = []
    private var closedWith: AgentError?

    func put(_ item: Result<Value, AgentError>) {
        if waiters.isEmpty {
            items.append(item)
        } else {
            waiters.removeFirst().resume(returning: item)
        }
    }

    func close(_ error: AgentError) {
        guard closedWith == nil else { return }
        closedWith = error
        for waiter in waiters { waiter.resume(returning: .failure(error)) }
        waiters = []
    }

    func next() async -> Result<Value, AgentError> {
        if !items.isEmpty { return items.removeFirst() }
        if let closedWith { return .failure(closedWith) }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// A wall-clock deadline rather than a count of sleeps: on a starved runner each sleep
/// overshoots, and a passing condition returns at once anyway.
func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
