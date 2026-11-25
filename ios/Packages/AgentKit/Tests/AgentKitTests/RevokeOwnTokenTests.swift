import AgentAPI
import Foundation
import Testing

@testable import AgentKit

/// `DELETE /v1/tokens/self`: success and a retry after success both end with the device unpaired.
@Suite struct RevokeOwnTokenTests {
    private static func failure(_ status: Int, _ code: ErrorCode) -> Operations.RevokeOwnToken.Output {
        .default(
            statusCode: status,
            .init(
                headers: .init(xRequestId: "r"),
                body: .json(.init(code: code, message: "", requestId: "r"))
            )
        )
    }

    @Test func noContentIsDone() throws {
        try LiveAgentClient.revokeOutcome(.noContent(.init(headers: .init(xRequestId: "r"))))
    }

    @Test func unauthorizedRetryIsDone() throws {
        try LiveAgentClient.revokeOutcome(Self.failure(401, .unauthorized))
    }

    @Test func otherErrorsReachTheCaller() {
        #expect(throws: AgentError.server(.rateLimited, requestId: "r")) {
            try LiveAgentClient.revokeOutcome(Self.failure(429, .rateLimited))
        }
        #expect(throws: AgentError.server(._internal, requestId: "r")) {
            try LiveAgentClient.revokeOutcome(Self.failure(500, ._internal))
        }
    }

    @Test func fakeRevokesOrFailsWithItsMode() async throws {
        try await FakeAgentClient().revokeOwnToken(idempotencyKey: UUID())
        await #expect(throws: AgentError.unreachable) {
            try await FakeAgentClient(mode: .failing(.unreachable)).revokeOwnToken(idempotencyKey: UUID())
        }
    }
}
