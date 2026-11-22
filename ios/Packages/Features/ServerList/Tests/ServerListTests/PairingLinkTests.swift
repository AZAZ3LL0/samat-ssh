import Foundation
import Testing

@testable import ServerList

/// S1.2 acceptance: `pulse-agent pair` prints `pulse://pair?h=<host>&p=<port>&fp=<spki>&c=<code>`;
/// the app reads exactly that and nothing else.
@Suite struct PairingLinkTests {
    static let fingerprint = "F0sRU55fRw86KcEnEi8xyNqveEHDm5UWO5HH3sx8F_E"

    private func link(_ string: String) -> PairingLink? {
        URL(string: string).flatMap(PairingLink.init(url:))
    }

    @Test(arguments: [
        ("vps.example.com", "https://vps.example.com:8443"),
        ("10.0.0.1", "https://10.0.0.1:8443"),
        // url.QueryEscape in the agent turns brackets and colons into %XX.
        ("%5Bfe80%3A%3A1%5D", "https://[fe80::1]:8443"),
        ("fe80%3A%3A1", "https://[fe80::1]:8443"),
    ])
    func readsWhatTheAgentPrints(host: String, endpoint: String) throws {
        let parsed = try #require(link("pulse://pair?h=\(host)&p=8443&fp=\(Self.fingerprint)&c=ABCDEF23"))
        #expect(parsed.endpoint.absoluteString == endpoint)
        #expect(parsed.fingerprint == Self.fingerprint)
        #expect(parsed.code == "ABCDEF23")
    }

    @Test func toleratesLowercaseCodeAndParameterOrder() throws {
        let parsed = try #require(link("pulse://pair?c=abcdef23&fp=\(Self.fingerprint)&p=7443&h=host"))
        #expect(parsed.code == "ABCDEF23")
        #expect(parsed.endpoint.absoluteString == "https://host:7443")
    }

    @Test(arguments: [
        "https://pair?h=host&p=7443&fp=\(fingerprint)&c=ABCDEF23",  // another scheme
        "pulse://unpair?h=host&p=7443&fp=\(fingerprint)&c=ABCDEF23",  // another action
        "pulse://pair?p=7443&fp=\(fingerprint)&c=ABCDEF23",  // no host
        "pulse://pair?h=ho%20st&p=7443&fp=\(fingerprint)&c=ABCDEF23",  // not a host
        "pulse://pair?h=host&fp=\(fingerprint)&c=ABCDEF23",  // no port
        "pulse://pair?h=host&p=0&fp=\(fingerprint)&c=ABCDEF23",
        "pulse://pair?h=host&p=70000&fp=\(fingerprint)&c=ABCDEF23",
        "pulse://pair?h=host&p=7443&c=ABCDEF23",  // no fingerprint
        "pulse://pair?h=host&p=7443&fp=short&c=ABCDEF23",
        "pulse://pair?h=host&p=7443&fp=\(fingerprint)=&c=ABCDEF23",  // padded, not base64url
        "pulse://pair?h=host&p=7443&fp=\(fingerprint)",  // no code
        "pulse://pair?h=host&p=7443&fp=\(fingerprint)&c=ABCDEF1",  // 1 is not base32
        "pulse://pair?h=host&p=7443&fp=\(fingerprint)&c=ABCDEF234",  // 9 characters
    ])
    func rejectsAnythingElse(_ string: String) {
        #expect(link(string) == nil)
    }
}
