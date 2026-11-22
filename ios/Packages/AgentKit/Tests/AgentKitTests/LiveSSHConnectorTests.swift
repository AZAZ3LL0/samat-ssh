import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH
import Testing

@testable import AgentKit

/// `LiveSSHConnector` against an SSH server in this process (Citadel's server side): the host key
/// the user sees, the key check before any credential is sent, password and key logins, and exec.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LiveSSHConnectorTests {
    @Test func readsTheHostKeyWithoutLoggingIn() async throws {
        try await TestSSHServer.with { server in
            let key = try await LiveSSHConnector().hostKey(host: "127.0.0.1", port: server.port)
            #expect(key == server.hostKey)
            #expect(server.auth.attempts == 0)
        }
    }

    @Test func otherHostKeyFailsBeforeThePasswordIsSent() async throws {
        try await TestSSHServer.with { server in
            await #expect(throws: SSHError.hostKeyMismatch(presented: server.hostKey)) {
                _ = try await LiveSSHConnector().connect(
                    host: "127.0.0.1", port: server.port, user: "root", auth: .password(TestSSHServer.password),
                    trusting: SSHKeyPair.generate().publicKey)
            }
            #expect(server.auth.attempts == 0)
        }
    }

    @Test func wrongPasswordFailsAsAuthentication() async throws {
        try await TestSSHServer.with { server in
            await #expect(throws: SSHError.authenticationFailed) {
                _ = try await LiveSSHConnector().connect(
                    host: "127.0.0.1", port: server.port, user: "root", auth: .password("wrong"),
                    trusting: server.hostKey)
            }
        }
    }

    // Stdin (`sudo -S`) is not checked here: Citadel's server drops channel data that arrives before it
    // has set up the exec pipes, while OpenSSH queues it for the command. The install flow checks it
    // against a real sshd.
    @Test func runsCommandsWithStatusAndOutput() async throws {
        try await TestSSHServer.with { server in
            let session = try await LiveSSHConnector().connect(
                host: "127.0.0.1", port: server.port, user: "root", auth: .password(TestSSHServer.password),
                trusting: server.hostKey)
            #expect(try await session.run("uname -m") == SSHOutput(status: 0, stdout: "x86_64\n", stderr: ""))
            #expect(try await session.run("fail") == SSHOutput(status: 3, stdout: "", stderr: "boom\n"))
            await session.close()
        }
    }

    @Test func logsInWithTheAppKey() async throws {
        let pair = SSHKeyPair.generate()
        try await TestSSHServer.with(authorizedKey: pair.publicKey) { server in
            let session = try await LiveSSHConnector().connect(
                host: "127.0.0.1", port: server.port, user: "admin", auth: .key(pair), trusting: server.hostKey)
            #expect(try await session.run("uname -m").status == 0)
            await session.close()
        }
    }

    @Test func closedPortIsUnreachable() async throws {
        let port = try freePort()
        await #expect(throws: SSHError.unreachable) {
            _ = try await LiveSSHConnector().hostKey(host: "127.0.0.1", port: port)
        }
    }
}

/// A loopback SSH server: password `TestSSHServer.password`, or `authorizedKey`, and two commands.
struct TestSSHServer {
    static let password = "correct horse"

    let port: Int
    let hostKey: SSHPublicKey
    let auth: TestAuth

    static func with<T>(
        authorizedKey: SSHPublicKey? = nil, _ body: (TestSSHServer) async throws -> T
    ) async throws -> T {
        let privateKey = Curve25519.Signing.PrivateKey()
        let auth = TestAuth(authorizedKey: authorizedKey)
        let port = try freePort()
        let server = try await SSHServer.host(
            host: "127.0.0.1", port: port, hostKeys: [NIOSSHPrivateKey(ed25519Key: privateKey)],
            authenticationDelegate: auth)
        server.enableExec(withDelegate: TestExec())
        let hostKey = try #require(
            SSHPublicKey(openSSH: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: privateKey).publicKey)))
        do {
            let result = try await body(TestSSHServer(port: port, hostKey: hostKey, auth: auth))
            try? await server.close()
            return result
        } catch {
            try? await server.close()
            throw error
        }
    }
}

/// A port nothing listens on right now. Citadel keeps the server's bound address internal,
/// so the test asks the system for one and hands it to the server.
func freePort() throws -> Int {
    let handle = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(handle) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(handle, $0, length) == 0 && getsockname(handle, $0, &length) == 0
        }
    }
    try #require(bound)
    return Int(UInt16(bigEndian: address.sin_port))
}

final class TestAuth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {  // counter behind a lock
    private let lock = NSLock()
    private var count = 0
    private let authorizedKey: SSHPublicKey?

    init(authorizedKey: SSHPublicKey?) {
        self.authorizedKey = authorizedKey
    }

    var attempts: Int { lock.withLock { count } }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.password, .publicKey] }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        lock.withLock { count += 1 }
        switch request.request {
        case .password(let password) where password.password == TestSSHServer.password:
            responsePromise.succeed(.success)
        case .publicKey(let key) where SSHPublicKey(openSSH: String(openSSHPublicKey: key.publicKey)) == authorizedKey:
            responsePromise.succeed(.success)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

final class TestExec: ExecDelegate, @unchecked Sendable {  // stateless
    struct Context: ExecCommandContext {
        func terminate() async throws {}
    }

    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}

    func start(command: String, outputHandler: ExecOutputHandler) async throws -> any ExecCommandContext {
        DispatchQueue.global().async {
            let stdout = outputHandler.stdoutPipe.fileHandleForWriting
            let stderr = outputHandler.stderrPipe.fileHandleForWriting
            var status = 0
            switch command {
            case "uname -m":
                stdout.write(Data("x86_64\n".utf8))
            default:
                stderr.write(Data("boom\n".utf8))
                status = 3
            }
            try? stdout.close()
            try? stderr.close()
            // Citadel closes the channel on succeed; give NIO time to drain the pipes first.
            Thread.sleep(forTimeInterval: 0.2)
            outputHandler.succeed(exitCode: status)
        }
        return Context()
    }
}
