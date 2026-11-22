import CryptoKit
import Foundation

/// An SSH public key as an OpenSSH line, `<algorithm> <base64 blob>`: a server's host key or the app's key.
public struct SSHPublicKey: Sendable, Hashable {
    /// `<algorithm> <base64 blob>`, without a comment. The form `authorized_keys` and the Keychain hold.
    public let openSSH: String
    public let algorithm: String
    private let blob: Data

    /// Reads `<algorithm> <base64 blob> [comment]`. `nil` unless the blob is a well-formed key of that algorithm.
    public init?(openSSH line: String) {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let algorithm = String(fields[0])
        guard Self.isWellFormed(blob, algorithm: algorithm) else { return nil }
        self.init(algorithm: algorithm, blob: blob)
    }

    init(algorithm: String, blob: Data) {
        self.algorithm = algorithm
        self.blob = blob
        openSSH = "\(algorithm) \(blob.base64EncodedString())"
    }

    /// `SHA256:<base64>`, exactly as `ssh-keygen -lf` prints it, for the user to compare.
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// The blob is a sequence of SSH strings (RFC 4251 5) whose first one names the algorithm.
    private static func isWellFormed(_ blob: Data, algorithm: String) -> Bool {
        var rest = blob[...]
        var fields: [Data] = []
        while !rest.isEmpty {
            guard rest.count >= 4 else { return false }
            let length = rest.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            rest = rest.dropFirst(4)
            guard rest.count >= length else { return false }
            fields.append(Data(rest.prefix(length)))
            rest = rest.dropFirst(length)
        }
        guard let name = fields.first, name == Data(algorithm.utf8) else { return false }
        switch algorithm {
        case "ssh-ed25519": return fields.count == 2 && fields[1].count == 32
        case "ssh-rsa": return fields.count == 3
        default: return fields.count >= 2
        }
    }
}

/// The Ed25519 key the app generates per server and appends to `authorized_keys`.
/// Its raw bytes live only in the Keychain as `ssh.key.<serverId>`.
public struct SSHKeyPair: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    public static func generate() -> SSHKeyPair {
        SSHKeyPair(privateKey: Curve25519.Signing.PrivateKey())
    }

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Bytes read back from the Keychain.
    public init(rawRepresentation: Data) throws(SSHError) {
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw .invalidPrivateKey
        }
    }

    /// The 32-byte seed for the Keychain.
    public var rawRepresentation: Data { privateKey.rawRepresentation }

    public var publicKey: SSHPublicKey {
        var blob = Data()
        for field in [Data("ssh-ed25519".utf8), privateKey.publicKey.rawRepresentation] {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return SSHPublicKey(algorithm: "ssh-ed25519", blob: blob)
    }

    /// One `authorized_keys` line. The comment keeps only safe characters: a newline in a device name
    /// would otherwise start a second line, a key or options of someone else's choosing.
    public func authorizedKeysLine(comment: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-")
        let safe = String(String.UnicodeScalarView(comment.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        return safe.isEmpty ? publicKey.openSSH : "\(publicKey.openSSH) \(safe)"
    }
}

extension SSHKeyPair: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SSHKeyPair(\(publicKey.fingerprint))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
