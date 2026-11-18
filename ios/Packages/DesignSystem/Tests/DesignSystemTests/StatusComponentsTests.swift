import AgentKit
import Foundation
import Testing

@testable import DesignSystem

@Suite struct ErrorBannerTests {
    static let errors: [AgentError] = [
        .unreachable, .timeout, .unauthorized, .pinMismatch, .decoding,
        .incompatibleAgent(agent: 1, required: 2), .incompatibleClient(min: 3),
    ]

    @Test func everyErrorHasItsOwnText() {
        let texts = Self.errors.map(ErrorBanner.message(for:))
        #expect(!texts.contains(""))
        #expect(Set(texts).count == texts.count)
    }

    @Test(arguments: ErrorCode.allCases)
    func everyServerCodeHasText(code: ErrorCode) {
        #expect(!ErrorBanner.message(for: .server(code, requestId: "r-1")).isEmpty)
    }

    @Test func serverCodesOtherThanUnauthorizedAreDistinct() {
        let texts = ErrorCode.allCases.filter { $0 != .unauthorized }
            .map { ErrorBanner.message(for: .server($0, requestId: "r-1")) }
        #expect(Set(texts).count == texts.count)
    }

    @Test func revokedTokenReadsTheSameFromTransportAndFromServer() {
        #expect(
            ErrorBanner.message(for: .unauthorized) == ErrorBanner.message(for: .server(.unauthorized, requestId: "r")))
    }

    @Test func versionErrorsNameTheVersions() {
        let agent = ErrorBanner.message(for: .incompatibleAgent(agent: 1, required: 2))
        #expect(agent.contains("1") && agent.contains("2"))
        #expect(ErrorBanner.message(for: .incompatibleClient(min: 7)).contains("7"))
    }
}

@Suite struct ConnectionIndicatorTests {
    @Test func staleStateSaysHowOldTheDataIs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let title = ConnectionIndicator.title(for: .stale(since: now.addingTimeInterval(-300)), now: now)
        #expect(title.contains(DSFormat.relative(now.addingTimeInterval(-300), now: now)))
    }

    @Test func everyStateHasItsOwnTitle() {
        let states: [ConnectionState] = [.connecting, .connected, .offline, .stale(since: .distantPast)]
        let titles = states.map { ConnectionIndicator.title(for: $0) }
        #expect(Set(titles).count == states.count)
    }
}
