import Foundation

struct URLSessionWebSocketConnector: WebSocketConnector {
    let session: URLSession
    let url: URL
    let token: String?
    let delegate: PinningDelegate

    func connect() async throws(AgentError) -> any WebSocketConnection {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task, delegate: delegate)
    }
}

/// A failed upgrade surfaces on the first receive, so errors are mapped there.
struct URLSessionWebSocketConnection: WebSocketConnection {
    let task: URLSessionWebSocketTask
    let delegate: PinningDelegate

    func send(_ text: String) async throws(AgentError) {
        do {
            try await task.send(.string(text))
        } catch {
            throw failure(error)
        }
    }

    func receive() async throws(AgentError) -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw failure(error)
        }
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(bytes: data, encoding: .utf8) else { throw .decoding }
            return text
        @unknown default:
            throw .decoding
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func failure(_ error: any Error) -> AgentError {
        if (task.response as? HTTPURLResponse)?.statusCode == 401 {
            return .unauthorized
        }
        return AgentError(error, pinRejected: delegate.didRejectPin)
    }
}
