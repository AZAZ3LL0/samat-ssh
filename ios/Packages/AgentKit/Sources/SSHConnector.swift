import Citadel
import CryptoKit
import Foundation

/// SSH to a server for installing and updating the agent (tech.md 4.1, docs/adr/0001).
///
/// Trust on first use: `hostKey` reads the server's key without sending any credential, the user
/// compares its fingerprint, and `connect` then trusts exactly that key.
public protocol SSHConnector: Sendable {
    /// The server's host key. The connection ends right after key exchange: no login is attempted.
    func hostKey(host: String, port: Int) async throws(SSHError) -> SSHPublicKey
    /// Logs in only if the server presents `trusting`; any other key fails before `auth` is sent.
    func connect(
        host: String, port: Int, user: String, auth: SSHAuth, trusting: SSHPublicKey
    ) async throws(SSHError) -> any SSHSession
}

public protocol SSHSession: Sendable {
    /// Runs `command` and waits for it to exit. A non-zero exit is a result, not an error.
    /// - Parameter stdinLine: written to stdin followed by a newline, for `sudo -S`. Stdin is
    ///   never closed, so a command that reads stdin to the end waits forever.
    func run(_ command: String, stdinLine: String?) async throws(SSHError) -> SSHOutput
    func close() async
}

extension SSHSession {
    public func run(_ command: String) async throws(SSHError) -> SSHOutput {
        try await run(command, stdinLine: nil)
    }
}

public struct SSHOutput: Sendable, Equatable {
    public let status: Int
    public let stdout: String
    public let stderr: String

    public init(status: Int, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum SSHError: Error, Sendable, Equatable {
    case unreachable, timeout
    /// The server refused the password or key.
    case authenticationFailed
    /// The server presented another key than the one the user confirmed.
    case hostKeyMismatch(presented: SSHPublicKey)
    /// A pasted or stored private key that cannot be read, or one with a wrong passphrase.
    case invalidPrivateKey
    /// The connection dropped while a command ran.
    case disconnected
}

/// How to log in. Never stored: a password serves one install (docs/adr/0001).
public struct SSHAuth: Sendable {
    enum Method: Sendable {
        case password(String)
        case ed25519(Curve25519.Signing.PrivateKey)
        /// Kept as text: Citadel's RSA key is not `Sendable`. Parsed once up front to fail early.
        case rsa(openSSH: String, passphrase: Data?)
    }

    let method: Method

    public static func password(_ password: String) -> SSHAuth {
        SSHAuth(method: .password(password))
    }

    public static func key(_ pair: SSHKeyPair) -> SSHAuth {
        SSHAuth(method: .ed25519(pair.privateKey))
    }

    /// A private key the user pasted, as `ssh-keygen` writes it: Ed25519 or RSA, optionally encrypted.
    public static func privateKey(openSSH text: String, passphrase: String?) throws(SSHError) -> SSHAuth {
        let decryptionKey = passphrase.map { Data($0.utf8) }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey) {
            return SSHAuth(method: .ed25519(key))
        }
        guard (try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryptionKey)) != nil else {
            throw .invalidPrivateKey
        }
        return SSHAuth(method: .rsa(openSSH: text, passphrase: decryptionKey))
    }
}

extension SSHAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch method {
        case .password: "SSHAuth(password)"
        case .ed25519, .rsa: "SSHAuth(key)"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
