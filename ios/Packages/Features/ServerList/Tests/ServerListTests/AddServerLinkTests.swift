import AgentKit
import Foundation
import Persistence
import SwiftData
import Testing

@testable import ServerList

/// S1.2 acceptance: a scanned QR code or a `pulse://pair` deep link fills the address and code,
/// the agent must present the key from the link, and pairing then saves the server as in S1.1.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AddServerLinkTests {
    let container: ModelContainer
    let secrets = InMemorySecretStore()

    init() throws {
        container = try PulseStore.makeContainer(inMemory: true)
    }

    private func model(_ pairing: any AgentPairing = FakeAgentPairing()) -> AddServerModel {
        AddServerModel(pairing: pairing, secrets: secrets, context: container.mainContext, deviceName: "Test iPhone")
    }

    private func records() throws -> [ServerRecord] {
        try container.mainContext.fetch(FetchDescriptor<ServerRecord>())
    }

    private func url(
        fingerprint: String = FakeAgentPairing.fingerprint, code: String = FakeAgentClient.pairingCode
    ) throws -> URL {
        try #require(URL(string: "pulse://pair?h=demo.local&p=8443&fp=\(fingerprint)&c=\(code)"))
    }

    @Test func linkSkipsManualCheckAndPairsAfterOneTap() async throws {
        let model = model()
        await model.open(try url())
        guard case .code(let probe) = model.step else {
            Issue.record("expected the code step, got \(model.step)")
            return
        }
        #expect(probe.fingerprint == FakeAgentPairing.fingerprint)
        #expect(model.host == "demo.local")
        #expect(model.port == "8443")
        #expect(model.code == FakeAgentClient.pairingCode)
        #expect(model.name == "demo")
        // Nothing is stored until the user taps Pair: a link from a web page must not add servers.
        #expect(try records().isEmpty)

        await model.pair()
        let record = try #require(try records().first)
        #expect(model.step == .paired(record.id))
        #expect(record.port == 8443)
        #expect(secrets.read(.spki(record.id)).flatMap { String(data: $0, encoding: .utf8) }
            == FakeAgentPairing.fingerprint)
    }

    @Test func agentWithAnotherKeyIsRefused() async throws {
        let model = model()
        await model.open(try url(fingerprint: String(repeating: "A", count: 43)))
        #expect(model.step == .address)
        #expect(model.error == .pinMismatch)
        #expect(model.code.isEmpty)
        #expect(try records().isEmpty)
    }

    @Test func invalidLinkNeverReachesNetwork() async throws {
        let model = model(FakeAgentPairing(mode: .failing(.unreachable)))
        await model.open(try #require(URL(string: "pulse://pair?h=demo.local")))
        #expect(model.invalidLink)
        #expect(model.step == .address)
        #expect(model.error == nil)
        #expect(model.host.isEmpty)
    }

    @Test func unreachableAgentKeepsAddressForRetry() async throws {
        let model = model(FakeAgentPairing(mode: .failing(.unreachable)))
        await model.open(try url())
        #expect(model.step == .address)
        #expect(model.error == .unreachable)
        #expect(model.host == "demo.local")
        #expect(model.port == "8443")
    }

    /// Expired and used codes both come back as `401 unauthorized`; the code step stays for a new code.
    @Test func expiredOrUsedCodeStaysOnCodeStep() async throws {
        let model = model()
        await model.open(try url(code: "ZZZZZZZZ"))
        await model.pair()
        guard case .code = model.step else {
            Issue.record("expected to stay on the code step, got \(model.step)")
            return
        }
        #expect(model.error == .unauthorized)
        #expect(try records().isEmpty)
    }

    @Test func newLinkClearsPreviousState() async throws {
        let model = model()
        await model.open(try #require(URL(string: "pulse://nope")))
        #expect(model.invalidLink)
        await model.open(try url())
        #expect(!model.invalidLink)
        #expect(model.error == nil)
    }
}
