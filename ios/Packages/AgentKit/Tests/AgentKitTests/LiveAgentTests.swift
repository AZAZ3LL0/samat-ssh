import Foundation
import Testing

@testable import AgentKit

/// `LiveAgentClient` against a real agent: the test VPS after each deploy, or any agent by hand.
/// `deploy/vps/check.sh` pairs, runs this suite through `make ios-vps-check` and revokes the
/// token. Skipped unless `PULSE_VPS_URL` is set: xcodebuild hands the test process every
/// `TEST_RUNNER_*` variable without the prefix.
@Suite(.enabled(if: LiveAgentTarget.requested), .serialized, .timeLimit(.minutes(1)))
struct LiveAgentTests {
    let target: LiveAgentTarget

    init() throws {
        target = try LiveAgentTarget.fromEnvironment()
    }

    @Test func pinnedPublicEndpointAnswers() async throws {
        let info = try await LiveAgentClient(baseURL: target.url, pin: target.pin, token: nil).info()
        try AgentCompatibility.check(info)
    }

    @Test func tokenOpensRESTAndWebSocket() async throws {
        let client = LiveAgentClient(baseURL: target.url, pin: target.pin, token: target.token)
        let metrics = try await client.hostMetrics()
        #expect((0...1).contains(metrics.cpu.usageRatio))

        var events = 0
        for try await _ in client.subscribe(.metricsHost).prefix(1) {
            events += 1
        }
        #expect(events == 1)
    }

    @Test func otherKeyFailsWithPinMismatch() async {
        // Well-formed, but the SHA-256 of no key the agent holds.
        let client = LiveAgentClient(baseURL: target.url, pin: String(repeating: "A", count: 43), token: target.token)
        await #expect(throws: AgentError.pinMismatch) { try await client.info() }
        await #expect(throws: AgentError.pinMismatch) { try await client.hostMetrics() }
    }

    @Test func unknownTokenIsUnauthorized() async {
        let client = LiveAgentClient(baseURL: target.url, pin: target.pin, token: "revoked-or-never-issued")
        await #expect(throws: AgentError.unauthorized) { try await client.hostMetrics() }
    }
}

struct LiveAgentTarget {
    let url: URL
    let pin: String
    let token: String

    static var requested: Bool {
        ProcessInfo.processInfo.environment["PULSE_VPS_URL"] != nil
    }

    /// Fails instead of skipping once the URL is set, so a half-configured run cannot pass.
    static func fromEnvironment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        return Self(
            url: try #require(environment["PULSE_VPS_URL"].flatMap(URL.init(string:))),
            pin: try #require(environment["PULSE_VPS_PIN"]),
            token: try #require(environment["PULSE_VPS_TOKEN"])
        )
    }
}
