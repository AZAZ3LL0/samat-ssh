import AgentAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// `AgentClient` over HTTPS and WebSocket with the agent's SPKI pinned.
public final class LiveAgentClient: AgentClient {
    private let session: URLSession
    private let delegate: PinningDelegate
    private let client: Client
    private let transport: WebSocketTransport

    /// - Parameters:
    ///   - baseURL: `https://<host>:<port>`, without the `/v1` prefix.
    ///   - pin: the SPKI fingerprint from pairing.
    ///   - token: the device token; `nil` before pairing, when only public endpoints answer.
    public init(baseURL: URL, pin: String, token: String?) {
        let delegate = PinningDelegate(pin: pin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        self.delegate = delegate
        self.client = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: .iso8601WithFractionalSeconds),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: token.map { [BearerAuth(token: $0)] } ?? []
        )
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/v1/ws"
        let socketURL = components?.url ?? baseURL.appending(path: "v1/ws")
        self.transport = WebSocketTransport(
            connector: URLSessionWebSocketConnector(session: session, url: socketURL, token: token, delegate: delegate)
        )
    }

    deinit {
        // The session retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    public func info() async throws(AgentError) -> AgentInfo {
        switch try await call({ try await self.client.getInfo() }) {
        case .ok(let response):
            return try decodeBody { try response.body.json }
        case .default(let status, let response):
            throw AgentError(status: status, body: try? response.body.json)
        }
    }

    public func hostMetrics() async throws(AgentError) -> HostMetrics {
        switch try await call({ try await self.client.getMetricsHost() }) {
        case .ok(let response):
            return try decodeBody { try response.body.json }
        case .default(let status, let response):
            throw AgentError(status: status, body: try? response.body.json)
        }
    }

    public func subscribe<T: Decodable & Sendable>(
        _ topic: WsTopic<T>
    ) -> AsyncThrowingStream<WsEvent<T>, any Error> {
        transport.subscribe(topic)
    }

    private func call<T>(_ operation: () async throws -> T) async throws(AgentError) -> T {
        do {
            return try await operation()
        } catch {
            throw AgentError(error, pinRejected: delegate.didRejectPin)
        }
    }

    private func decodeBody<T>(_ body: () throws -> T) throws(AgentError) -> T {
        do {
            return try body()
        } catch {
            throw .decoding
        }
    }
}

/// Adds the device token. The token never reaches a log: this is the only place that reads it.
private struct BearerAuth: ClientMiddleware {
    let token: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}
