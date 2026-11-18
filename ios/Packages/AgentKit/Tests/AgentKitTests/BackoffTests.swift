import Testing

@testable import AgentKit

@Suite struct BackoffTests {
    private let backoff = Backoff()

    @Test(arguments: 0..<40, [-1.0, -0.5, 0, 0.5, 1])
    func staysWithinJitterOfNominal(attempt: Int, random: Double) {
        let nominal = min(0.5 * Double(1 << min(attempt, 20)), 30)
        let delay = backoff.delay(attempt: attempt, random: random).seconds
        #expect(delay >= nominal * 0.8 - 1e-9)
        #expect(delay <= nominal * 1.2 + 1e-9)
    }

    @Test func doublesFromHalfASecondUpToThirty() {
        let delays = (0..<10).map { backoff.delay(attempt: $0, random: 0).seconds }
        #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30, 30, 30])
    }

    @Test func resetsAfterAMinuteOfStableConnection() {
        #expect(backoff.resetAfter == .seconds(60))
    }
}
