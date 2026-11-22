import Foundation
import Testing

@testable import AgentKit

/// S1.3: the user compares the host key with `ssh-keygen -lf`, and the server accepts the app's key
/// from `authorized_keys`. Vectors come from `ssh-keygen` (OpenSSH 9), not from this code.
@Suite struct SSHKeysTests {
    /// A throwaway key made for this test with `ssh-keygen -t ed25519 -C pulse@test`; it guards nothing.
    static let seed = "3FaMtZTXFHO4rEMtlRPFDuzHHVej7RQ1yBrO7KOios4="
    static let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP6+wuQT/YBjuoA0kOxTNKcD+qbJxu/22Tjyyw2D4JEB"
    /// `ssh-keygen -lf` of `publicLine`.
    static let fingerprint = "SHA256:kF6KqT0xy8r1VL5uy2/hE3ML0TjAmTWhX5H8TejT324"
    /// The same key as `ssh-keygen` writes it.
    static let privateKeyFile = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACD+vsLkE/2AY7qANJDsUzSnA/qmycbv9tk48ssNg+CRAQAAAJAP6D/+D+g/
        /gAAAAtzc2gtZWQyNTUxOQAAACD+vsLkE/2AY7qANJDsUzSnA/qmycbv9tk48ssNg+CRAQ
        AAAEDcVoy1lNcUc7isQy2VE8UO7McdV6PtFDXIGs7so6Kizv6+wuQT/YBjuoA0kOxTNKcD
        +qbJxu/22Tjyyw2D4JEBAAAACnB1bHNlQHRlc3QBAgM=
        -----END OPENSSH PRIVATE KEY-----
        """

    @Test func fingerprintMatchesSshKeygen() throws {
        let key = try #require(SSHPublicKey(openSSH: Self.publicLine + " pulse@test"))
        #expect(key.fingerprint == Self.fingerprint)
        // The comment is not part of the key.
        #expect(key.openSSH == Self.publicLine)
        #expect(key == SSHPublicKey(openSSH: Self.publicLine))
    }

    @Test func rsaFingerprintMatchesSshKeygen() throws {
        let line = """
            ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDj/7H9nkG+8CcqSebs55AMPi3EJbnrfpxSkR2GEaRNcIqIj+g/xK\
            SzyLK/TzM6oCjh6eUr4ZK8damSERP+A2bmRlm/02YB44xe9XOTx3p6YoqlB7KUJj+P8nBq104i006FlGKav8yomIEs\
            eaSYs4cWzK16Pf2Q6TG6GM4GA3zOWf2XQ8qz+iIgmUO41gyI5BAsNLN98d+7lcJszGc42gyusqh6PPx6FRVahvk5sU\
            9C1bJ3E8bNSha5A3hJ0n4q6AcvwJX1u+99iyq4/ToWvHIYX8V49r8q/aMS6s9jcpxRABeY2Bx8GpNP/3V0EM9nYkc5\
            tr+WbhZ0+ZdzCI4xz5uf
            """
        let key = try #require(SSHPublicKey(openSSH: line))
        #expect(key.algorithm == "ssh-rsa")
        #expect(key.fingerprint == "SHA256:gMmy2cTb/euJC1mOpKYb98YtJEu3v/1wT+ZLdQaPQr4")
    }

    @Test(arguments: [
        "",
        "ssh-ed25519",
        "ssh-ed25519 not-base64!",
        // The blob names another algorithm than the line.
        "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIP6+wuQT/YBjuoA0kOxTNKcD+qbJxu/22Tjyyw2D4JEB",
        // A truncated blob.
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
    ])
    func rejectsMalformedKeys(_ line: String) {
        #expect(SSHPublicKey(openSSH: line) == nil)
    }

    @Test func keyFromKeychainBytesHasTheSamePublicKey() throws {
        let seed = try #require(Data(base64Encoded: Self.seed))
        let pair = try SSHKeyPair(rawRepresentation: seed)
        #expect(pair.publicKey.openSSH == Self.publicLine)
        #expect(pair.rawRepresentation == seed)
        #expect(throws: SSHError.invalidPrivateKey) { try SSHKeyPair(rawRepresentation: Data([1, 2, 3])) }
    }

    @Test func generatedKeysDifferAndSurviveTheKeychain() throws {
        let first = SSHKeyPair.generate()
        let second = SSHKeyPair.generate()
        #expect(first.publicKey != second.publicKey)
        let restored = try SSHKeyPair(rawRepresentation: first.rawRepresentation)
        #expect(restored.publicKey == first.publicKey)
        #expect(first.publicKey.algorithm == "ssh-ed25519")
    }

    @Test func authorizedKeysLineIsOneLineWhateverTheDeviceName() throws {
        let pair = try SSHKeyPair(rawRepresentation: try #require(Data(base64Encoded: Self.seed)))
        #expect(pair.authorizedKeysLine(comment: "pulse@Samat's iPhone") == Self.publicLine + " pulse@Samat-s-iPhone")
        // A newline in the comment would add a second key of someone else's choosing.
        let hostile = pair.authorizedKeysLine(comment: "x\nssh-ed25519 AAAA attacker")
        #expect(!hostile.contains("\n"))
        #expect(hostile.split(separator: " ").count == 3)
        #expect(SSHPublicKey(openSSH: hostile) == pair.publicKey)
    }

    @Test func pastedPrivateKeyIsAccepted() throws {
        _ = try SSHAuth.privateKey(openSSH: Self.privateKeyFile, passphrase: nil)
        #expect(throws: SSHError.invalidPrivateKey) {
            try SSHAuth.privateKey(openSSH: "-----BEGIN OPENSSH PRIVATE KEY-----\nnope\n", passphrase: nil)
        }
    }

    @Test func secretsStayOutOfDescriptions() throws {
        let seed = try #require(Data(base64Encoded: Self.seed))
        let values: [Any] = [
            SSHAuth.password("hunter2-secret"),
            SSHAuth.key(try SSHKeyPair(rawRepresentation: seed)),
            try SSHKeyPair(rawRepresentation: seed),
            try SSHAuth.privateKey(openSSH: Self.privateKeyFile, passphrase: nil),
        ]
        for value in values {
            for text in [String(describing: value), String(reflecting: value), "\(value)", dumped(value)] {
                #expect(!text.contains("hunter2"))
                #expect(!text.contains("3FaMtZTX"))
                #expect(!text.contains("b3BlbnNz"))
            }
        }
    }

    private func dumped(_ value: Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }
}
