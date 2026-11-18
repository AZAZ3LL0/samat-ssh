import CryptoKit
import Foundation
import Security
import os

/// SHA-256 of a certificate's SubjectPublicKeyInfo, base64url without padding:
/// the value `pulse-agent pair` prints as `fp`.
public enum SPKIFingerprint {
    /// `nil` for a key the agent never generates; the caller treats that as a mismatch.
    public static func of(_ certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
            let attributes = SecKeyCopyAttributes(key) as? [String: Any],
            attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
            let bits = attributes[kSecAttrKeySizeInBits as String] as? Int,
            let header = ecHeaders[bits],
            let point = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else {
            return nil
        }
        let digest = SHA256.hash(data: header + point)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Security returns only the raw EC point; the DER prefix rebuilds the
    /// SubjectPublicKeyInfo for the curve. The agent uses P-256, P-384 costs nothing.
    private static let ecHeaders: [Int: Data] = [
        256: Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ]),
        384: Data([
            0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
        ]),
    ]
}

/// Accepts exactly the agent whose leaf certificate matches the pin. The agent's
/// certificate is self-signed, so the pin replaces CA validation; there is no
/// "trust anyway" path, re-pinning happens only through pairing again.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    private let pin: String
    private let rejected = OSAllocatedUnfairLock(initialState: false)

    init(pin: String) {
        self.pin = pin
    }

    /// True once a server presented a different key; URLSession reports that only as a cancellation.
    var didRejectPin: Bool { rejected.withLock { $0 } }

    static func matches(_ trust: SecTrust, pin: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else {
            return false
        }
        return SPKIFingerprint.of(leaf) == pin
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        guard Self.matches(trust, pin: pin) else {
            rejected.withLock { $0 = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
