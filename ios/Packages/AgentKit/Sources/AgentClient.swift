import AgentAPI
import Foundation

/// The app's only way to talk to an agent. Features depend on this protocol,
/// `LiveAgentClient` and `FakeAgentClient` implement it.
public protocol AgentClient: Sendable {
    func info() async throws(AgentError) -> AgentInfo
    func hostMetrics() async throws(AgentError) -> HostMetrics
    /// Events of a topic until the consumer stops iterating. The stream survives
    /// reconnects; it finishes with an `AgentError` only when retrying cannot help.
    func subscribe<T: Decodable & Sendable>(
        _ topic: WsTopic<T>
    ) -> AsyncThrowingStream<WsEvent<T>, any Error>
    // Slices add methods here only together with the contract.
}

/// A WebSocket topic from `x-ws-topics` in `api/openapi.yaml` and the payload type of its events.
public struct WsTopic<Payload>: Sendable, Hashable {
    public let name: String
    public let params: [String: String]

    public init(name: String, params: [String: String] = [:]) {
        self.name = name
        self.params = params
    }
}

extension WsTopic where Payload == HostMetrics {
    public static var metricsHost: Self { Self(name: "metrics.host") }
}

public struct WsEvent<Payload: Sendable>: Sendable {
    public let seq: Int64
    /// Agent time of the event, `ts` of the envelope.
    public let timestamp: Date
    public let payload: Payload

    public init(seq: Int64, timestamp: Date, payload: Payload) {
        self.seq = seq
        self.timestamp = timestamp
        self.payload = payload
    }
}
