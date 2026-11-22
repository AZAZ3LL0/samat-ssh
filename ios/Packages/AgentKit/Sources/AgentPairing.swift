import Foundation

/// What an agent shows before it is trusted: its info and the SPKI fingerprint of its key.
public struct AgentProbe: Sendable, Equatable {
    public let info: AgentInfo
    /// SHA-256 of the SPKI, base64url: the `fingerprint` line of `pulse-agent pair`.
    public let fingerprint: String

    public init(info: AgentInfo, fingerprint: String) {
        self.info = info
        self.fingerprint = fingerprint
    }
}

/// Adding a server: look at an unknown agent, then pair with the key the user confirmed.
public protocol AgentPairing: Sendable {
    /// `GET /v1/info` trusting whatever key the agent presents.
    func probe(_ baseURL: URL) async throws(AgentError) -> AgentProbe
    /// `POST /v1/pair` pinned to `pin`, so a key swapped after the user's check fails as `pinMismatch`.
    func pair(_ baseURL: URL, pin: String, code: String, deviceName: String) async throws(AgentError) -> PairResponse
}

public struct LiveAgentPairing: AgentPairing {
    public init() {}

    public func probe(_ baseURL: URL) async throws(AgentError) -> AgentProbe {
        try await LiveAgentClient.probe(baseURL: baseURL)
    }

    public func pair(
        _ baseURL: URL, pin: String, code: String, deviceName: String
    ) async throws(AgentError) -> PairResponse {
        try await LiveAgentClient(baseURL: baseURL, pin: pin, token: nil).pair(code: code, deviceName: deviceName)
    }
}

/// Pairing against `FakeAgentClient` at any address: demo mode, previews and tests.
public struct FakeAgentPairing: AgentPairing {
    /// The fingerprint every fake agent presents.
    public static let fingerprint = "F0sRU55fRw86KcEnEi8xyNqveEHDm5UWO5HH3sx8F_E"

    private let client: FakeAgentClient

    public init(mode: FakeAgentClient.Mode = .normal) {
        client = FakeAgentClient(mode: mode)
    }

    public func probe(_ baseURL: URL) async throws(AgentError) -> AgentProbe {
        AgentProbe(info: try await client.info(), fingerprint: Self.fingerprint)
    }

    public func pair(
        _ baseURL: URL, pin: String, code: String, deviceName: String
    ) async throws(AgentError) -> PairResponse {
        // Stands in for TLS pinning: a pin other than the presented key never reaches the agent.
        guard pin == Self.fingerprint else { throw .pinMismatch }
        return try await client.pair(code: code, deviceName: deviceName)
    }
}
