import AgentKit
import Foundation
import Persistence
import SwiftData
import Testing

@testable import ServerList

/// S1.1 acceptance: host and port → `GET /v1/info` → fingerprint to compare with `pulse-agent pair`
/// → pairing code → `ServerRecord` plus token and pin in the Keychain.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AddServerModelTests {
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

    private func string(_ account: KeychainAccount) -> String? {
        secrets.read(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func pairsAndStoresRecordTokenAndPin() async throws {
        let model = model()
        model.host = "demo.local"
        await model.connect()
        guard case .verify(let probe) = model.step else {
            Issue.record("expected the fingerprint check, got \(model.step)")
            return
        }
        #expect(probe.fingerprint == FakeAgentPairing.fingerprint)
        #expect(probe.info.hostname == "demo")

        model.confirmFingerprint()
        #expect(model.name == "demo")
        model.code = FakeAgentClient.pairingCode
        await model.pair()

        let record = try #require(try records().first)
        #expect(model.step == .paired(record.id))
        #expect(record.name == "demo")
        #expect(record.host == "demo.local")
        #expect(record.port == 7443)
        #expect(record.lastApiVersion == probe.info.apiVersion)
        #expect(record.lastSeenAt != nil)
        #expect(string(.spki(record.id)) == FakeAgentPairing.fingerprint)
        #expect(string(.token(record.id))?.isEmpty == false)
    }

    @Test(arguments: [
        ("example.com", "7443", "https://example.com:7443"),
        (" 10.0.0.1 ", "8443", "https://10.0.0.1:8443"),
        ("::1", "7443", "https://[::1]:7443"),
        ("[fe80::1]", "1", "https://[fe80::1]:1"),
    ])
    func acceptsHostsAndPorts(host: String, port: String, url: String) {
        let model = model()
        model.host = host
        model.port = port
        #expect(model.endpoint?.absoluteString == url)
    }

    @Test(arguments: [
        ("", "7443"), ("exa mple.com", "7443"), ("https://example.com", "7443"), ("example.com/x", "7443"),
        ("example.com", ""), ("example.com", "0"), ("example.com", "65536"), ("example.com", "abc"),
    ])
    func rejectsInvalidAddressWithoutNetwork(host: String, port: String) async {
        let model = model(FakeAgentPairing(mode: .failing(.unreachable)))
        model.host = host
        model.port = port
        #expect(model.endpoint == nil)
        await model.connect()
        #expect(model.step == .address)
        #expect(model.error == nil)
    }

    @Test(arguments: [AgentError.unreachable, .timeout, .pinMismatch, .decoding])
    func unreachableAgentStaysOnAddress(error: AgentError) async throws {
        let model = model(FakeAgentPairing(mode: .failing(error)))
        model.host = "demo.local"
        await model.connect()
        #expect(model.step == .address)
        #expect(model.error == error)
        #expect(try records().isEmpty)
    }

    @Test func refusesAgentThatNeedsNewerApp() async throws {
        let info = try await FakeAgentClient().info()
        let newer = AgentInfo(
            agentVersion: info.agentVersion, apiVersion: 99, minClientApiVersion: 99,
            hostname: info.hostname, features: info.features)
        let model = model(StubPairing(probe: AgentProbe(info: newer, fingerprint: FakeAgentPairing.fingerprint)))
        model.host = "demo.local"
        await model.connect()
        #expect(model.step == .address)
        #expect(model.error == .incompatibleClient(min: 99))
    }

    @Test func mismatchedFingerprintStoresNothing() async throws {
        let model = model()
        model.host = "demo.local"
        await model.connect()
        model.rejectFingerprint()
        #expect(model.step == .address)
        #expect(try records().isEmpty)
        #expect(model.code.isEmpty)
    }

    @Test func wrongCodeKeepsCodeStepAndStoresNothing() async throws {
        let model = model()
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        model.code = "AAAAAAAA"
        await model.pair()
        guard case .code = model.step else {
            Issue.record("expected to stay on the code step, got \(model.step)")
            return
        }
        #expect(model.error == .unauthorized)
        #expect(try records().isEmpty)

        // The user runs `pulse-agent pair` again and types the new code.
        model.code = FakeAgentClient.pairingCode
        await model.pair()
        #expect(try records().count == 1)
        #expect(model.error == nil)
    }

    @Test func keySwappedAfterCheckReturnsToAddress() async throws {
        let info = try await FakeAgentClient().info()
        // The probe sees one key, pairing pins it, the agent then presents another one.
        let model = model(StubPairing(probe: AgentProbe(info: info, fingerprint: "other"), pairError: .pinMismatch))
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        model.code = FakeAgentClient.pairingCode
        await model.pair()
        #expect(model.step == .address)
        #expect(model.error == .pinMismatch)
        #expect(try records().isEmpty)
    }

    @Test func emptyCodeDoesNotPair() async throws {
        let model = model()
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        model.code = "  "
        #expect(!model.canPair)
        await model.pair()
        #expect(try records().isEmpty)
    }

    @Test func pairingSameAddressAgainReplacesSecretsOfExistingRecord() async throws {
        let existing = ServerRecord(name: "web", host: "demo.local", sortOrder: 0)
        container.mainContext.insert(existing)
        secrets.write(Data("old".utf8), for: .token(existing.id))
        secrets.write(Data("old".utf8), for: .spki(existing.id))

        let model = model()
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        #expect(model.name == "web")
        model.code = FakeAgentClient.pairingCode
        await model.pair()

        #expect(try records().map(\.id) == [existing.id])
        #expect(model.step == .paired(existing.id))
        #expect(string(.spki(existing.id)) == FakeAgentPairing.fingerprint)
        #expect(string(.token(existing.id)) != "old")
    }

    @Test func newServerGoesLast() async throws {
        container.mainContext.insert(ServerRecord(name: "a", host: "a.local", sortOrder: 4))
        let model = model()
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        model.name = "  custom  "
        model.code = FakeAgentClient.pairingCode
        await model.pair()
        let record = try #require(try records().first { $0.host == "demo.local" })
        #expect(record.sortOrder == 5)
        #expect(record.name == "custom")
    }

    @Test func sendsDeviceNameWithinContractLimit() async throws {
        let recorder = StubPairing(probe: AgentProbe(info: try await FakeAgentClient().info(), fingerprint: "fp"))
        let model = AddServerModel(
            pairing: recorder, secrets: secrets, context: container.mainContext,
            deviceName: String(repeating: "й", count: 100))
        model.host = "demo.local"
        await model.connect()
        model.confirmFingerprint()
        model.code = "abcd efgh"
        await model.pair()
        let sent = try #require(recorder.lastPair)
        #expect(sent.deviceName.count == 64)
        #expect(sent.pin == "fp")
        #expect(sent.code == "ABCDEFGH")
    }
}

/// A pairing double with a fixed probe that records what pairing sends.
private final class StubPairing: AgentPairing, @unchecked Sendable {  // accessed from the main actor only
    let probe: AgentProbe
    let pairError: AgentError?
    struct Sent {
        let pin: String
        let code: String
        let deviceName: String
    }

    private(set) var lastPair: Sent?

    init(probe: AgentProbe, pairError: AgentError? = nil) {
        self.probe = probe
        self.pairError = pairError
    }

    func probe(_ baseURL: URL) async throws(AgentError) -> AgentProbe { probe }

    func pair(
        _ baseURL: URL, pin: String, code: String, deviceName: String
    ) async throws(AgentError) -> PairResponse {
        lastPair = Sent(pin: pin, code: code, deviceName: deviceName)
        if let pairError { throw pairError }
        return PairResponse(token: "token", tokenId: "id")
    }
}
