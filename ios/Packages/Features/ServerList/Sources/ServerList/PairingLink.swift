import Foundation

/// `pulse://pair?h=<host>&p=<port>&fp=<spki>&c=<code>`, as `pulse-agent pair` prints it and its QR code holds.
public struct PairingLink: Sendable, Equatable {
    public let host: String
    public let port: Int
    /// SHA-256 of the agent's SPKI, base64url without padding.
    public let fingerprint: String
    /// One-time code: 8 base32 characters.
    public let code: String
    /// `https://<host>:<port>` of the agent.
    public let endpoint: URL

    /// `nil` for anything that is not a complete pairing link; nothing in it reaches the network.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "pulse", url.host?.lowercased() == "pair",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let host = value("h").flatMap(AddServerModel.normalizedHost),
            let port = value("p").flatMap(Int.init), (1...65535).contains(port),
            let fingerprint = value("fp"), Self.isFingerprint(fingerprint),
            let code = value("c")?.uppercased(), Self.isCode(code),
            let endpoint = Self.endpoint(host: host, port: port)
        else { return nil }
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
        self.endpoint = endpoint
    }

    private static func endpoint(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }

    private static func isFingerprint(_ value: String) -> Bool {
        let base64url = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        // 32 bytes of SHA-256 encode to 43 characters without padding.
        return value.count == 43 && value.unicodeScalars.allSatisfy(base64url.contains)
    }

    private static func isCode(_ value: String) -> Bool {
        let base32 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        return value.count == 8 && value.unicodeScalars.allSatisfy(base32.contains)
    }
}
