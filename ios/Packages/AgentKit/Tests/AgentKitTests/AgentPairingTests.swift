import Foundation
import Testing

@testable import AgentKit

/// S1.1: the user checks the agent's key before pairing, and pairing trusts only that key.
@Suite(.timeLimit(.minutes(1))) struct AgentPairingTests {
    @Test func probeWithoutPinAcceptsAgentKeyAndRecordsIt() {
        let delegate = PinningDelegate(pin: nil)
        #expect(delegate.accept(SPKIPinningTests.agentPin))
        #expect(delegate.presentedFingerprint == SPKIPinningTests.agentPin)
        #expect(!delegate.didRejectPin)
    }

    @Test func probeRejectsKeyAgentNeverGenerates() {
        let delegate = PinningDelegate(pin: nil)
        #expect(!delegate.accept(nil))
        #expect(delegate.didRejectPin)
    }

    @Test func pinnedDelegateRejectsOtherKeyAndReportsIt() {
        let delegate = PinningDelegate(pin: SPKIPinningTests.agentPin)
        #expect(!delegate.accept(SPKIPinningTests.impostorPin))
        #expect(delegate.didRejectPin)
        #expect(delegate.presentedFingerprint == SPKIPinningTests.impostorPin)
        #expect(PinningDelegate(pin: SPKIPinningTests.agentPin).accept(SPKIPinningTests.agentPin))
    }

    @Test func fakePairsWithDemoCodeFromFixture() async throws {
        let response = try await FakeAgentClient().pair(code: " demo2345 ", deviceName: "iPhone")
        #expect(!response.token.isEmpty)
        #expect(!response.tokenId.isEmpty)
    }

    @Test(arguments: ["", "AAAAAAAA", "DEMO2346"])
    func fakeRejectsUnknownCodeLikeAgent(code: String) async {
        await #expect(throws: AgentError.unauthorized) {
            try await FakeAgentClient().pair(code: code, deviceName: "iPhone")
        }
    }

    @Test func failingFakeFailsPairing() async {
        await #expect(throws: AgentError.server(.rateLimited, requestId: "r")) {
            try await FakeAgentClient(mode: .failing(.server(.rateLimited, requestId: "r")))
                .pair(code: FakeAgentClient.pairingCode, deviceName: "iPhone")
        }
    }

    @Test func fakePairingNeedsThePresentedKey() async throws {
        let pairing = FakeAgentPairing()
        let url = try #require(URL(string: "https://demo.local:7443"))
        let probe = try await pairing.probe(url)
        #expect(probe.info.hostname == "demo")
        #expect(probe.fingerprint == FakeAgentPairing.fingerprint)

        _ = try await pairing.pair(url, pin: probe.fingerprint, code: FakeAgentClient.pairingCode, deviceName: "x")
        await #expect(throws: AgentError.pinMismatch) {
            try await pairing.pair(
                url, pin: SPKIPinningTests.agentPin, code: FakeAgentClient.pairingCode, deviceName: "x")
        }
    }
}
