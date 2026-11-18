import AgentAPI
import Fixtures
import Foundation

/// `AgentClient` on the seed data in `fixtures/`: demo mode, previews and tests.
/// Fixtures pass `make validate-fixtures`, so whatever this client returns is
/// something a real agent could send.
public struct FakeAgentClient: AgentClient {
    public enum Mode: Sendable, Equatable {
        case normal
        /// Every call fails with this error; streams finish with it.
        case failing(AgentError)
        /// Every response and event is delayed by `slowDelay`.
        case slow
        /// Streams finish with `.unreachable` after this many events, like a dropped socket.
        case dropWebSocket(after: Int)
    }

    /// Topics in `x-ws-topics` of `api/openapi.yaml`. A test keeps the two in sync.
    static let contractTopics: Set<String> = ["debug.echo", "metrics.host"]
    static let slowDelay: Duration = .seconds(2)

    private let mode: Mode
    private let interval: Duration

    /// - Parameter interval: time between events; the agent publishes `metrics.host` every second.
    public init(mode: Mode = .normal, interval: Duration = .seconds(1)) {
        self.mode = mode
        self.interval = interval
    }

    public func info() async throws(AgentError) -> AgentInfo {
        try await respond { () throws(AgentError) in try Self.load("agent_info/demo.json") }
    }

    public func hostMetrics() async throws(AgentError) -> HostMetrics {
        try await respond { () throws(AgentError) in try Self.load(Self.paths("host_metrics")[0]) }
    }

    public func subscribe<T: Decodable & Sendable>(
        _ topic: WsTopic<T>
    ) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        precondition(Self.contractTopics.contains(topic.name), "\(topic.name) is not a topic in api/openapi.yaml")
        let (mode, interval) = (mode, interval)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do throws(AgentError) {
                    if case .failing(let error) = mode { throw error }
                    // debug.echo only answers echo messages, which this client never sends.
                    guard topic.name == "metrics.host" else { return }
                    let payloads: [T] = try Self.paths("host_metrics").map { path throws(AgentError) in
                        try Self.load(path)
                    }
                    var seq: Int64 = 0
                    while !Task.isCancelled {
                        if case .dropWebSocket(let limit) = mode, seq >= limit { throw .unreachable }
                        let delay = mode == .slow ? interval + Self.slowDelay : interval
                        if seq > 0 { try? await Task.sleep(for: delay) }
                        let payload = payloads[Int(seq) % payloads.count]
                        seq += 1
                        continuation.yield(WsEvent(seq: seq, timestamp: .now, payload: payload))
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func respond<T>(_ body: () throws(AgentError) -> T) async throws(AgentError) -> T {
        switch mode {
        case .failing(let error):
            throw error
        case .slow:
            try? await Task.sleep(for: Self.slowDelay)
        case .normal, .dropWebSocket:
            break
        }
        return try body()
    }

    private static func paths(_ directory: String) throws(AgentError) -> [String] {
        do {
            return try Fixtures.paths(in: directory)
        } catch {
            throw .decoding
        }
    }

    /// Fixtures decode with the generated types; a failure here is a contract mismatch.
    private static func load<T: Decodable>(_ path: String) throws(AgentError) -> T {
        do {
            return try AgentJSON.decoder.decode(T.self, from: Fixtures.data(path))
        } catch {
            throw .decoding
        }
    }
}
