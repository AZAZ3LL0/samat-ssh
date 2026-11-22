import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// `SSHConnector` on Citadel (SwiftNIO SSH).
public struct LiveSSHConnector: SSHConnector {
    /// Output kept per stream; `install.sh` and `pair --json` print a few kilobytes.
    static let outputLimit = 1 << 20

    private let connectTimeout: Duration

    public init(connectTimeout: Duration = .seconds(15)) {
        self.connectTimeout = connectTimeout
    }

    public func hostKey(host: String, port: Int) async throws(SSHError) -> SSHPublicKey {
        // Fails the key exchange on purpose once the key is seen, so no login follows.
        let recorder = HostKeyCheck(trusted: nil)
        do {
            let client = try await SSHClient.connect(
                to: settings(host: host, port: port, check: recorder) { .passwordBased(username: "", password: "") })
            try? await client.close()
        } catch {
            if let key = recorder.presented { return key }
            throw Self.map(error)
        }
        // Unreachable: the check never lets a key exchange finish.
        throw .unreachable
    }

    public func connect(
        host: String, port: Int, user: String, auth: SSHAuth, trusting key: SSHPublicKey
    ) async throws(SSHError) -> any SSHSession {
        let check = HostKeyCheck(trusted: key)
        // Citadel's method is not `Sendable`, so the closure builds it; a key that cannot be read fails here.
        _ = try Self.method(auth, user: user)
        let method: @Sendable () -> SSHAuthenticationMethod = {
            (try? Self.method(auth, user: user)) ?? .passwordBased(username: user, password: "")
        }
        do {
            let client = try await SSHClient.connect(to: settings(host: host, port: port, check: check, method: method))
            return LiveSSHSession(client: client)
        } catch {
            if let presented = check.presented, presented != key { throw .hostKeyMismatch(presented: presented) }
            throw Self.map(error)
        }
    }

    private func settings(
        host: String, port: Int, check: HostKeyCheck, method: @escaping @Sendable () -> SSHAuthenticationMethod
    ) -> SSHClientSettings {
        var settings = SSHClientSettings(
            host: host, port: port, authenticationMethod: method, hostKeyValidator: .custom(check))
        let (seconds, attoseconds) = connectTimeout.components
        settings.connectTimeout = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        return settings
    }

    private static func method(_ auth: SSHAuth, user: String) throws(SSHError) -> SSHAuthenticationMethod {
        switch auth.method {
        case .password(let password):
            return .passwordBased(username: user, password: password)
        case .ed25519(let key):
            return .ed25519(username: user, privateKey: key)
        case .rsa(let text, let passphrase):
            guard let key = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: passphrase) else {
                throw .invalidPrivateKey
            }
            return .rsa(username: user, privateKey: key)
        }
    }

    static func map(_ error: any Error) -> SSHError {
        switch error {
        case let error as SSHError:
            return error
        case is AuthenticationFailed, SSHClientError.allAuthenticationOptionsFailed:
            return .authenticationFailed
        case let error as ChannelError:
            switch error {
            case .connectTimeout: return .timeout
            case .ioOnClosedChannel, .alreadyClosed, .eof: return .disconnected
            default: return .unreachable
            }
        default:
            return .unreachable
        }
    }
}

/// Validates the host key during key exchange and remembers what the server presented.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {  // state behind lock
    private let trusted: SSHPublicKey?
    private let lock = NSLock()
    private var seen: SSHPublicKey?

    /// - Parameter trusted: the confirmed key, or `nil` to record the key and stop.
    init(trusted: SSHPublicKey?) {
        self.trusted = trusted
    }

    var presented: SSHPublicKey? { lock.withLock { seen } }

    struct Rejected: Error {}

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = SSHPublicKey(openSSH: String(openSSHPublicKey: hostKey))
        lock.withLock { seen = key }
        if let trusted, key == trusted {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(Rejected())
        }
    }
}

final class LiveSSHSession: SSHSession, @unchecked Sendable {  // SSHClient runs on its own event loop
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    func run(_ command: String, stdinLine: String?) async throws(SSHError) -> SSHOutput {
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        var status = 0
        var exited = false
        do {
            try await client.withExec(command) { inbound, outbound in
                if let stdinLine {
                    try await outbound.write(ByteBuffer(string: stdinLine + "\n"))
                }
                do {
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer): try Self.append(buffer, to: &stdout)
                        case .stderr(let buffer): try Self.append(buffer, to: &stderr)
                        }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    status = failed.exitCode
                }
                exited = true
            }
        } catch let error as ChannelError where exited && error == .alreadyClosed {
            // The server closed the channel after the exit status; closing it again from here races that.
        } catch {
            throw LiveSSHConnector.map(error)
        }
        return SSHOutput(status: status, stdout: String(buffer: stdout), stderr: String(buffer: stderr))
    }

    func close() async {
        try? await client.close()
    }

    private static func append(_ chunk: ByteBuffer, to buffer: inout ByteBuffer) throws(SSHError) {
        guard buffer.readableBytes + chunk.readableBytes <= LiveSSHConnector.outputLimit else { throw .disconnected }
        buffer.writeImmutableBuffer(chunk)
    }
}
