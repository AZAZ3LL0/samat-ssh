import Foundation
import Testing

@testable import AgentAPI

@Suite struct GeneratedTypesTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @Test func decodesAgentInfo() throws {
        let json = Data(
            """
            {"agentVersion":"0.1.0","apiVersion":1,"minClientApiVersion":1,
             "hostname":"demo","features":["host_metrics","history"]}
            """.utf8
        )
        let info = try decoder.decode(Components.Schemas.AgentInfo.self, from: json)
        #expect(info.apiVersion == 1)
        #expect(info.features == [.hostMetrics, .history])
    }

    @Test func decodesErrorWithKnownCode() throws {
        let json = Data(#"{"code":"rate_limited","message":"slow down","requestId":"r-1"}"#.utf8)
        let error = try decoder.decode(Components.Schemas._Error.self, from: json)
        #expect(error.code == .rateLimited)
        #expect(error.requestId == "r-1")
    }

    @Test func rejectsUnknownErrorCode() {
        let json = Data(#"{"code":"made_up","message":"","requestId":"r-1"}"#.utf8)
        #expect(throws: (any Swift.Error).self) {
            try decoder.decode(Components.Schemas._Error.self, from: json)
        }
    }
}
