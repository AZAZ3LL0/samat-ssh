import AgentAPI
import Foundation
import OpenAPIRuntime

typealias WsEnvelope = Components.Schemas.WsEnvelope

/// One open WebSocket. Errors arrive as `AgentError`, so the transport can
/// tell what a reconnect can fix from what it cannot.
protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws(AgentError)
    func receive() async throws(AgentError) -> String
    func close()
}

protocol WebSocketConnector: Sendable {
    func connect() async throws(AgentError) -> any WebSocketConnection
}

/// Reconnect delays, `tech.md` 6.7: 0.5 s doubling up to 30 s, jitter ±20%,
/// reset once a connection has stayed up for 60 s.
struct Backoff: Sendable {
    var initial: Duration = .milliseconds(500)
    var maximum: Duration = .seconds(30)
    var jitter = 0.2
    var resetAfter: Duration = .seconds(60)

    /// - Parameters:
    ///   - attempt: 0 for the first retry after a failure.
    ///   - random: a value in `-1...1` that picks the jitter.
    func delay(attempt: Int, random: Double) -> Duration {
        let nominal = min(initial.seconds * pow(2, Double(min(attempt, 32))), maximum.seconds)
        return .seconds(nominal * (1 + jitter * random))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Multiplexes topic subscriptions over one WebSocket per agent and keeps them
/// alive: reconnects with backoff, subscribes again after every reconnect,
/// answers pings, treats 45 s of silence as a dead connection and starts a
/// subscription over when its `seq` skips.
actor WebSocketTransport {
    private struct Sink: Sendable {
        let deliver: @Sendable (WsEnvelope) -> Void
        let finish: @Sendable (AgentError) -> Void
    }

    /// One subscription on the wire, shared by every consumer of the same topic and params.
    private struct Subscription {
        let topic: String
        let params: [String: String]
        var requestId = ""
        /// Events before `subscribed` belong to the previous subscription and are skipped.
        var confirmed = false
        var lastSeq: Int64?
        var sinks: [UUID: Sink] = [:]
    }

    private let connector: any WebSocketConnector
    private let backoff: Backoff
    private let idleTimeout: Duration
    private let random: @Sendable () -> Double

    private var subscriptions: [String: Subscription] = [:]
    private var connection: (any WebSocketConnection)?
    private var loop: Task<Void, Never>?
    /// Consumers that stopped before their registration ran.
    private var cancelled: Set<UUID> = []

    init(
        connector: any WebSocketConnector,
        backoff: Backoff = Backoff(),
        idleTimeout: Duration = .seconds(45),
        random: @escaping @Sendable () -> Double = { .random(in: -1...1) }
    ) {
        self.connector = connector
        self.backoff = backoff
        self.idleTimeout = idleTimeout
        self.random = random
    }

    nonisolated func subscribe<T: Decodable & Sendable>(
        _ topic: WsTopic<T>
    ) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: WsEvent<T>.self)
        let id = UUID()
        let key = Self.key(topic)
        let sink = Sink(
            deliver: { envelope in
                guard let seq = envelope.seq else { return }
                do {
                    let payload = try AgentJSON.convert(envelope.payload, to: T.self)
                    continuation.yield(WsEvent(seq: seq, timestamp: envelope.ts, payload: payload))
                } catch {
                    continuation.finish(throwing: AgentError.decoding)
                }
            },
            finish: { continuation.finish(throwing: $0) }
        )
        continuation.onTermination = { _ in
            Task { await self.remove(id, key: key) }
        }
        Task { await self.add(id, sink: sink, topic: topic.name, params: topic.params, key: key) }
        return stream
    }

    private static func key<T>(_ topic: WsTopic<T>) -> String {
        let params = topic.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return ([topic.name] + params).joined(separator: "\u{0}")
    }

    // MARK: Consumers

    private func add(_ id: UUID, sink: Sink, topic: String, params: [String: String], key: String) async {
        if cancelled.remove(id) != nil { return }
        let isNew = subscriptions[key] == nil
        if isNew {
            subscriptions[key] = Subscription(topic: topic, params: params)
        }
        subscriptions[key]?.sinks[id] = sink
        if loop == nil {
            loop = Task { await run() }
        } else if isNew, let connection {
            // A failed send also breaks the receive loop, whose reconnect subscribes again.
            try? await subscribe(key, on: connection)
        }
    }

    private func remove(_ id: UUID, key: String) async {
        guard subscriptions[key]?.sinks.removeValue(forKey: id) != nil else {
            cancelled.insert(id)
            return
        }
        guard let subscription = subscriptions[key], subscription.sinks.isEmpty else { return }
        subscriptions[key] = nil
        if subscriptions.isEmpty {
            loop?.cancel()
            loop = nil
            connection?.close()
            connection = nil
        } else if let connection {
            try? await unsubscribe(subscription, on: connection)
        }
    }

    private func finishAll(_ error: AgentError) {
        for subscription in subscriptions.values {
            for sink in subscription.sinks.values { sink.finish(error) }
        }
        subscriptions = [:]
    }

    // MARK: Connection

    private func run() async {
        var attempt = 0
        while !Task.isCancelled, !subscriptions.isEmpty {
            let started = ContinuousClock.now
            let failure: AgentError
            do throws(AgentError) {
                let connection = try await connector.connect()
                guard !Task.isCancelled else {
                    connection.close()
                    return
                }
                self.connection = connection
                for key in subscriptions.keys {
                    try await subscribe(key, on: connection)
                }
                try await receive(on: connection)
                failure = .unreachable
            } catch {
                failure = error
            }
            connection?.close()
            connection = nil
            if Task.isCancelled { return }
            if failure.isFatal {
                finishAll(failure)
                break
            }
            if ContinuousClock.now - started >= backoff.resetAfter {
                attempt = 0
            }
            try? await Task.sleep(for: backoff.delay(attempt: attempt, random: random()))
            attempt += 1
        }
        if !Task.isCancelled {
            loop = nil
        }
    }

    private func receive(on connection: any WebSocketConnection) async throws(AgentError) {
        var watchdog = arm(connection)
        defer { watchdog.cancel() }
        while true {
            let text = try await connection.receive()
            watchdog.cancel()
            watchdog = arm(connection)
            try await handle(text, on: connection)
        }
    }

    /// Closes a connection that stays silent for `idleTimeout`; the agent pings every 15 s.
    private func arm(_ connection: any WebSocketConnection) -> Task<Void, Never> {
        Task { [idleTimeout] in
            guard (try? await Task.sleep(for: idleTimeout)) != nil else { return }
            connection.close()
        }
    }

    // MARK: Messages

    private func handle(_ text: String, on connection: any WebSocketConnection) async throws(AgentError) {
        guard let envelope = try? AgentJSON.decoder.decode(WsEnvelope.self, from: Data(text.utf8)) else {
            return
        }
        switch envelope._type {
        case .ping:
            try await send(.pong, topic: nil, payload: nil, on: connection)
        case .subscribed:
            confirm(envelope)
        case .event:
            try await deliver(envelope, on: connection)
        case .gap:
            // The agent continues `seq` after a gap, so the loss it reports is not a skip.
            for key in keys(forTopic: envelope.topic) {
                subscriptions[key]?.lastSeq = envelope.seq
            }
        case .error:
            reject(envelope)
        case .subscribe, .unsubscribe, .pong, .echo:
            return
        }
    }

    private func confirm(_ envelope: WsEnvelope) {
        guard let payload = decode(envelope.payload, as: Components.Schemas.WsSubscribedPayload.self),
            let key = key(forRequest: payload.requestId)
        else { return }
        subscriptions[key]?.confirmed = true
        subscriptions[key]?.lastSeq = nil
    }

    /// An error that names a subscribe request ends that subscription; other errors concern nobody's stream.
    private func reject(_ envelope: WsEnvelope) {
        guard let error = decode(envelope.payload, as: Components.Schemas._Error.self),
            let requestId = error.details?.additionalProperties.value["requestId"] as? String,
            let key = key(forRequest: requestId),
            let subscription = subscriptions.removeValue(forKey: key)
        else { return }
        for sink in subscription.sinks.values {
            sink.finish(.server(error.code, requestId: error.requestId))
        }
    }

    private func deliver(_ envelope: WsEnvelope, on connection: any WebSocketConnection) async throws(AgentError) {
        for key in keys(forTopic: envelope.topic) {
            guard let subscription = subscriptions[key], subscription.confirmed, let seq = envelope.seq else {
                continue
            }
            for sink in subscription.sinks.values { sink.deliver(envelope) }
            if let last = subscription.lastSeq, seq != last + 1 {
                try await unsubscribe(subscription, on: connection)
                try await subscribe(key, on: connection)
            } else {
                subscriptions[key]?.lastSeq = seq
            }
        }
    }

    private func subscribe(_ key: String, on connection: any WebSocketConnection) async throws(AgentError) {
        guard var subscription = subscriptions[key] else { return }
        subscription.requestId = UUID().uuidString.lowercased()
        subscription.confirmed = false
        subscription.lastSeq = nil
        subscriptions[key] = subscription

        var params: Components.Schemas.WsSubscribePayload.ParamsPayload?
        if !subscription.params.isEmpty {
            do {
                params = .init(additionalProperties: try OpenAPIObjectContainer(unvalidatedValue: subscription.params))
            } catch {
                throw .decoding
            }
        }
        let payload = Components.Schemas.WsSubscribePayload(requestId: subscription.requestId, params: params)
        try await send(.subscribe, topic: subscription.topic, payload: payload, on: connection)
    }

    private func unsubscribe(
        _ subscription: Subscription,
        on connection: any WebSocketConnection
    ) async throws(AgentError) {
        let payload = Components.Schemas.WsUnsubscribePayload(requestId: subscription.requestId)
        try await send(.unsubscribe, topic: subscription.topic, payload: payload, on: connection)
    }

    private func send(
        _ type: Components.Schemas.WsMessageType,
        topic: String?,
        payload: (any Encodable & Sendable)?,
        on connection: any WebSocketConnection
    ) async throws(AgentError) {
        let data: Data
        do {
            let container = try payload.map { try AgentJSON.convert($0, to: OpenAPIValueContainer.self) }
            data = try AgentJSON.encoder.encode(WsEnvelope(_type: type, topic: topic, ts: .now, payload: container))
        } catch {
            throw .decoding
        }
        guard let text = String(bytes: data, encoding: .utf8) else { throw .decoding }
        try await connection.send(text)
    }

    private func decode<T: Decodable>(_ payload: OpenAPIValueContainer?, as type: T.Type) -> T? {
        try? AgentJSON.convert(payload, to: type)
    }

    private func key(forRequest requestId: String) -> String? {
        subscriptions.first { $0.value.requestId == requestId }?.key
    }

    private func keys(forTopic topic: String?) -> [String] {
        subscriptions.filter { $0.value.topic == topic }.map(\.key)
    }
}
