import Foundation
import Testing

@testable import AgentKit

/// The fake behaves like a server for the install flow's tests: the same errors as the live connector,
/// scripted command output, and a record of what ran.
@Suite(.timeLimit(.minutes(1))) struct FakeSSHConnectorTests {
    private func connector(unreachable: Bool = false) -> FakeSSHConnector {
        FakeSSHConnector(password: "secret", unreachable: unreachable) { command in
            switch command {
            case "uname -m": SSHOutput(status: 0, stdout: "x86_64\n", stderr: "")
            case "false": SSHOutput(status: 1, stdout: "", stderr: "failed\n")
            default: nil
            }
        }
    }

    @Test func demoHostKeyIsAWellFormedKey() {
        #expect(SSHPublicKey(openSSH: FakeSSHConnector.hostKey.openSSH) == FakeSSHConnector.hostKey)
    }

    @Test func presentsItsHostKey() async throws {
        #expect(try await connector().hostKey(host: "demo.local", port: 22) == FakeSSHConnector.hostKey)
    }

    @Test func refusesAnotherTrustedKey() async throws {
        let other = SSHKeyPair.generate().publicKey
        await #expect(throws: SSHError.hostKeyMismatch(presented: FakeSSHConnector.hostKey)) {
            _ = try await connector().connect(
                host: "demo.local", port: 22, user: "root", auth: .password("secret"), trusting: other)
        }
    }

    @Test func refusesAWrongPassword() async {
        await #expect(throws: SSHError.authenticationFailed) {
            _ = try await connector().connect(
                host: "demo.local", port: 22, user: "root", auth: .password("wrong"),
                trusting: FakeSSHConnector.hostKey)
        }
    }

    @Test func unreachableServerFailsBeforeShowingAKey() async {
        await #expect(throws: SSHError.unreachable) {
            _ = try await connector(unreachable: true).hostKey(host: "demo.local", port: 22)
        }
    }

    @Test func runsScriptedCommandsAndRecordsThem() async throws {
        let connector = connector()
        let session = try await connector.connect(
            host: "demo.local", port: 22, user: "admin", auth: .key(.generate()), trusting: FakeSSHConnector.hostKey)
        #expect(try await session.run("uname -m") == SSHOutput(status: 0, stdout: "x86_64\n", stderr: ""))
        #expect(try await session.run("false", stdinLine: "secret").status == 1)
        await session.close()
        #expect(
            await connector.journal.commands == [
                FakeSSHJournal.Entry(user: "admin", command: "uname -m", stdinLine: nil),
                FakeSSHJournal.Entry(user: "admin", command: "false", stdinLine: "secret"),
            ])
    }
}
