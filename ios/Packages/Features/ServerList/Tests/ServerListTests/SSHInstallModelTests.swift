import AgentKit
import Foundation
import Persistence
import SwiftData
import Testing

@testable import ServerList

/// S1.3 acceptance: SSH login after the user confirms the host key, arch and distro check, `install.sh`
/// as root or through `sudo -S`, the app's key in `authorized_keys`, `pulse-agent pair --json`, pairing.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SSHInstallModelTests {
    nonisolated static let password = "s3cret-Pa55"

    let container: ModelContainer
    let secrets = InMemorySecretStore()

    init() throws {
        container = try PulseStore.makeContainer(inMemory: true)
    }

    private func model(_ server: TestServer, pairing: any AgentPairing = FakeAgentPairing()) -> SSHInstallModel {
        let model = SSHInstallModel(
            connector: server.connector, pairing: pairing, secrets: secrets, context: container.mainContext,
            deviceName: "Test iPhone", installScript: "#!/bin/sh\necho installed\n")
        model.host = "vps.example.com"
        model.user = server.user
        model.password = Self.password
        return model
    }

    /// Form → host key → confirmed → preflight. Ends on `.ready` unless the server refuses earlier.
    private func connect(_ model: SSHInstallModel) async {
        await model.readHostKey()
        await model.trustHostKey()
    }

    private func records() throws -> [ServerRecord] {
        try container.mainContext.fetch(FetchDescriptor<ServerRecord>())
    }

    private func storedSecrets(_ id: UUID) -> [Data] {
        [.token(id), .spki(id), .sshKey(id), .sshHostKey(id)].compactMap { secrets.read($0) }
    }

    @Test(arguments: [("x86_64", "amd64"), ("aarch64", "arm64"), ("amd64", "amd64"), ("arm64", "arm64")])
    func supportedArchitectureReachesReady(machine: String, arch: String) async {
        let server = TestServer(machine: machine)
        let model = model(server)
        await connect(model)
        guard case .ready(let facts) = model.step else {
            Issue.record("expected ready, got \(model.step), error \(String(describing: model.error))")
            return
        }
        #expect(facts.architecture == arch)
    }

    @Test(arguments: ["armv7l", "mips64", "i686"])
    func unsupportedArchitectureWritesNothing(machine: String) async throws {
        let server = TestServer(machine: machine)
        let model = model(server)
        await connect(model)
        #expect(model.error == .unsupportedArchitecture(machine))
        #expect(model.step == .form)
        let commands = await server.commands()
        #expect(!commands.contains { $0.command.contains("authorized_keys") || $0.command.contains("pair") })
        #expect(!commands.contains { $0.command.contains("base64") })
        #expect(try records().isEmpty)
    }

    @Test func rejectedHostKeyRunsNoCommand() async throws {
        let server = TestServer()
        let model = model(server)
        await model.readHostKey()
        #expect(model.step == .hostKey(FakeSSHConnector.hostKey))
        model.rejectHostKey()
        #expect(model.step == .form)
        #expect(await server.commands().isEmpty)
        #expect(try records().isEmpty)
    }

    @Test func sudoGetsPasswordOnlyThroughStdin() async throws {
        let server = TestServer(user: "deploy", uid: 1000)
        let model = model(server)
        await connect(model)
        #expect(model.step.isReady)
        await model.install()
        #expect(model.step.isPaired)

        let commands = await server.commands()
        #expect(commands.contains { $0.command.contains("pulse-agent pair --json") })
        for entry in commands {
            #expect(!entry.command.contains(Self.password))
            if entry.command.hasPrefix("sudo -S") {
                #expect(entry.stdinLine == Self.password)
            } else {
                #expect(entry.stdinLine == nil)
            }
        }
        // Installing and pairing need root; the key goes to the login user's own home.
        let sudo = commands.filter { $0.command.hasPrefix("sudo -S") }.map(\.command)
        #expect(sudo.contains { $0.contains("base64") })
        #expect(sudo.contains { $0.contains("pulse-agent pair --json") })
        #expect(!sudo.contains { $0.contains("authorized_keys") })
    }

    @Test func wrongSudoPasswordStops() async throws {
        let server = TestServer(user: "deploy", uid: 1000, sudoAccepts: false)
        let model = model(server)
        await connect(model)
        #expect(model.error == .sudoRefused)
        #expect(try records().isEmpty)
    }

    @Test func wrongPasswordReturnsToFormAndStoresNothing() async throws {
        let server = TestServer()
        let model = model(server)
        model.password = "wrong"
        await connect(model)
        #expect(model.error == .ssh(.authenticationFailed))
        #expect(model.step == .form)
        #expect(await server.commands().isEmpty)
        #expect(try records().isEmpty)
    }

    @Test func keyLoginWithoutPasswordlessSudoStops() async throws {
        let server = TestServer(user: "deploy", uid: 1000, passwordlessSudo: false)
        let model = model(server)
        model.password = ""
        model.privateKey = TestServer.pastedKey
        await connect(model)
        #expect(model.error == .keyNeedsPasswordlessSudo)
        let commands = await server.commands()
        #expect(!commands.contains { $0.command.contains("base64") || $0.command.contains("authorized_keys") })
        #expect(try records().isEmpty)
    }

    @Test func invalidPastedKeyFailsBeforeNetwork() async {
        let server = TestServer()
        let model = model(server)
        model.password = ""
        model.privateKey = "not a key"
        await model.readHostKey()
        #expect(model.error == .ssh(.invalidPrivateKey))
        #expect(model.step == .form)
    }

    @Test func rerunKeepsOneAuthorizedKeysLine() async throws {
        let server = TestServer()
        for _ in 0..<2 {
            let model = model(server)
            await connect(model)
            await model.install()
            #expect(model.step.isPaired)
        }
        #expect(await server.authorizedKeys().count == 1)
        #expect(try records().count == 1)
    }

    @Test func agentKeyDifferentFromPairOutputSavesNothing() async throws {
        let server = TestServer(pairFingerprint: "c29tZW9uZS1lbHNlcy1rZXk")
        let model = model(server)
        await connect(model)
        await model.install()
        #expect(model.error == .agent(.pinMismatch))
        #expect(!model.step.isPaired)
        #expect(try records().isEmpty)
    }

    @Test func failingInstallScriptStopsWithItsMessage() async throws {
        let server = TestServer(installFails: true)
        let model = model(server)
        await connect(model)
        await model.install()
        #expect(model.error == .commandFailed("install.sh: cannot find the latest agent release"))
        #expect(try records().isEmpty)
    }

    @Test func unsupportedDistroIsAWarningOnly() async {
        let server = TestServer(osRelease: "PRETTY_NAME=\"Fedora Linux 40\"\nID=fedora\nVERSION_ID=40\n")
        let model = model(server)
        await connect(model)
        guard case .ready(let facts) = model.step else {
            Issue.record("expected ready, got \(model.step)")
            return
        }
        #expect(!facts.supportedSystem)
        #expect(facts.systemName == "Fedora Linux 40")
    }

    /// The app ships deploy/install.sh itself, not a copy that can drift.
    @Test func bundlesDeployInstallScript() {
        let model = SSHInstallModel(
            connector: TestServer().connector, pairing: FakeAgentPairing(), secrets: secrets,
            context: container.mainContext, deviceName: "Test iPhone")
        #expect(model.installScript?.hasPrefix("#!/bin/sh") == true)
        #expect(model.installScript?.contains("pulse-agent") == true)
    }

    @Test func successStoresEverythingAndNoPassword() async throws {
        let server = TestServer(user: "deploy", uid: 1000)
        let model = model(server)
        await connect(model)
        guard case .ready(let facts) = model.step else {
            Issue.record("expected ready, got \(model.step)")
            return
        }
        #expect(facts.supportedSystem)
        #expect(facts.systemName == "Ubuntu 24.04.1 LTS")
        await model.install()

        let record = try #require(try records().first)
        #expect(model.step == .paired(record.id))
        #expect(record.host == "vps.example.com")
        #expect(record.port == 7443)
        #expect(record.name == "demo")
        #expect(record.sshHost == "vps.example.com")
        #expect(record.sshPort == 22)
        #expect(record.sshUser == "deploy")

        #expect(secrets.read(.token(record.id))?.isEmpty == false)
        #expect(secrets.read(.spki(record.id)) == Data(FakeAgentPairing.fingerprint.utf8))
        #expect(secrets.read(.sshHostKey(record.id)) == Data(FakeSSHConnector.hostKey.openSSH.utf8))
        let raw = try #require(secrets.read(.sshKey(record.id)))
        let key = try SSHKeyPair(rawRepresentation: raw)
        #expect(await server.authorizedKeys().contains { $0.hasPrefix(key.publicKey.openSSH) })

        let password = Data(Self.password.utf8)
        for secret in storedSecrets(record.id) {
            #expect(secret.range(of: password) == nil)
        }
        let fields = [record.name, record.host, record.sshHost, record.sshUser].compactMap { $0 }
        #expect(!fields.contains { $0.contains(Self.password) })
        #expect(model.password.isEmpty)
    }
}

extension SSHInstallModel.Step {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
    var isPaired: Bool {
        if case .paired = self { true } else { false }
    }
}

/// A fake server that answers the install's commands and keeps `authorized_keys` between runs.
struct TestServer {
    /// An unencrypted Ed25519 key in OpenSSH form, made for this test only.
    static let pastedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAJyK4cESTdSbwq9IhqHLVZVC4xA7sglUCCvXhTxZcdxAAAAJDN+GzCzfhs
        wgAAAAtzc2gtZWQyNTUxOQAAACAJyK4cESTdSbwq9IhqHLVZVC4xA7sglUCCvXhTxZcdxA
        AAAEDu8hfQyCrZDdPjv0nlqcxMukcUPbA7rdP46s/0vWCD3QnIrhwRJN1JvCr0iGoctVlU
        LjEDuyCVQIK9eFPFlx3EAAAACnRlc3RAcHVsc2UBAgM=
        -----END OPENSSH PRIVATE KEY-----
        """

    let user: String
    let connector: FakeSSHConnector
    private let keys: AuthorizedKeys

    init(
        user: String = "root", uid: Int = 0, machine: String = "x86_64",
        osRelease: String = "PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nID=ubuntu\nVERSION_ID=\"24.04\"\n",
        sudoAccepts: Bool = true, passwordlessSudo: Bool = true, installFails: Bool = false,
        pairFingerprint: String = FakeAgentPairing.fingerprint
    ) {
        self.user = user
        let keys = AuthorizedKeys()
        self.keys = keys
        let pairJSON = """
            {"host":"vps.example.com","port":7443,"fp":"\(pairFingerprint)","code":"\(FakeAgentClient.pairingCode)",\
            "expiresAt":"2026-11-22T10:10:00.000Z","url":"pulse://pair"}
            """
        let success: @Sendable (String) -> SSHOutput = { SSHOutput(status: 0, stdout: $0, stderr: "") }
        let failure: @Sendable (String) -> SSHOutput = { SSHOutput(status: 1, stdout: "", stderr: $0) }
        connector = FakeSSHConnector(password: SSHInstallModelTests.password) { command in
            switch command {
            case "uname -m": return success(machine + "\n")
            case "cat /etc/os-release": return success(osRelease)
            case "id -u": return success("\(uid)\n")
            case "sudo -S -p '' true": return sudoAccepts ? success("") : failure("")
            case "sudo -n true": return passwordlessSudo ? success("") : failure("sudo: a password is required")
            default: break
            }
            if command.contains("authorized_keys") {
                return keys.apply(command) ? success("") : nil
            }
            if command.contains("pulse-agent pair --json") { return success(pairJSON + "\n") }
            if command.contains("base64 -d") {
                return installFails
                    ? failure("Downloading\ninstall.sh: cannot find the latest agent release\n")
                    : success("pulse-agent 0.1.0 is running.\n")
            }
            return nil
        }
    }

    func commands() async -> [FakeSSHJournal.Entry] { await connector.journal.commands }
    func authorizedKeys() -> [String] { keys.lines }
}

/// `~/.ssh/authorized_keys` of the fake server: runs the `grep -qxF || echo >>` the install sends.
final class AuthorizedKeys: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] { lock.withLock { stored } }

    /// Reads the quoted line out of the command and appends it unless an identical line exists.
    func apply(_ command: String) -> Bool {
        guard let start = command.range(of: "grep -qxF '"),
            let end = command[start.upperBound...].firstIndex(of: "'")
        else { return false }
        let line = String(command[start.upperBound..<end])
        lock.withLock {
            if !stored.contains(line) { stored.append(line) }
        }
        return true
    }
}
