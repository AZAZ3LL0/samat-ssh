import AgentAPI
import Foundation
import OpenAPIRuntime
import Testing

@testable import AgentKit

@Suite struct AgentErrorTests {
    @Test func mapsUnauthorizedRegardlessOfBody() {
        let body = Components.Schemas._Error(code: .unauthorized, message: "", requestId: "r-1")
        #expect(AgentError(status: 401, body: body) == .unauthorized)
        #expect(AgentError(status: 401, body: nil) == .unauthorized)
    }

    @Test(arguments: [
        (429, ErrorCode.rateLimited), (409, .idempotencyConflict), (501, .unsupported), (503, .upstreamUnavailable),
    ])
    func mapsErrorBodyToServerError(status: Int, code: ErrorCode) {
        let body = Components.Schemas._Error(code: code, message: "for logs only", requestId: "r-7")
        #expect(AgentError(status: status, body: body) == .server(code, requestId: "r-7"))
    }

    @Test func treatsMissingErrorBodyAsDecodingFailure() {
        #expect(AgentError(status: 500, body: nil) == .decoding)
    }

    @Test func mapsTransportFailures() {
        #expect(AgentError(URLError(.timedOut), pinRejected: false) == .timeout)
        #expect(AgentError(URLError(.cannotConnectToHost), pinRejected: false) == .unreachable)
        #expect(AgentError(URLError(.notConnectedToInternet), pinRejected: false) == .unreachable)
        // URLSession reports a rejected pin as a plain cancellation.
        #expect(AgentError(URLError(.cancelled), pinRejected: true) == .pinMismatch)
        #expect(AgentError(AgentError.unauthorized, pinRejected: false) == .unauthorized)
    }

    @Test func onlyRepairingFixesUnauthorizedAndPinMismatch() {
        let fatal: [AgentError] = [.unauthorized, .pinMismatch]
        let retryable: [AgentError] = [.unreachable, .timeout, .decoding, .server(._internal, requestId: "r")]
        #expect(fatal.map(\.isFatal) == [true, true])
        #expect(retryable.map(\.isFatal) == [false, false, false, false])
    }
}

@Suite struct AgentCompatibilityTests {
    private func info(api: Int, minClient: Int) -> AgentInfo {
        AgentInfo(agentVersion: "0.1.0", apiVersion: api, minClientApiVersion: minClient, hostname: "h", features: [])
    }

    @Test func clientVersionIsTheContractVersion() throws {
        let spec = URL(filePath: #filePath).appending(path: "../../../../../../api/openapi.yaml").standardized
        let yaml = try String(contentsOf: spec, encoding: .utf8)
        let version = try #require(yaml.firstMatch(of: /\n  version: "(\d+)"/)?.1)
        #expect(Int(version) == AgentCompatibility.clientApiVersion)
    }

    @Test func acceptsMatchingVersions() throws {
        try AgentCompatibility.check(info(api: 2, minClient: 1))
        try AgentCompatibility.check(info(api: 5, minClient: 2), requiredApiVersion: 2)
    }

    @Test func rejectsOlderAgent() {
        #expect(throws: AgentError.incompatibleAgent(agent: 1, required: 2)) {
            try AgentCompatibility.check(info(api: 1, minClient: 1), requiredApiVersion: 2)
        }
    }

    @Test func rejectsOlderClient() {
        #expect(throws: AgentError.incompatibleClient(min: 3)) {
            try AgentCompatibility.check(info(api: 3, minClient: 3))
        }
    }
}

@Suite struct AgentJSONTests {
    @Test(arguments: ["2026-11-15T10:00:00.000Z", "2026-11-15T10:00:00Z"])
    func decodesRFC3339WithAndWithoutMilliseconds(text: String) throws {
        let date = try AgentJSON.decoder.decode(Date.self, from: Data("\"\(text)\"".utf8))
        #expect(date == Date(timeIntervalSince1970: 1_794_736_800))
    }

    @Test func encodesMilliseconds() throws {
        let data = try AgentJSON.encoder.encode(Date(timeIntervalSince1970: 1_794_736_800.25))
        #expect(String(bytes: data, encoding: .utf8) == "\"2026-11-15T10:00:00.250Z\"")
    }
}
