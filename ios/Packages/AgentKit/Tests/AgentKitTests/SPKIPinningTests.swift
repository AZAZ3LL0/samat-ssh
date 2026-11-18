import Foundation
import Security
import Testing

@testable import AgentKit

/// Throwaway self-signed P-256 certificates. Expected pins come from openssl:
/// `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary`,
/// base64url without padding, the same value `pulse-agent pair` prints.
@Suite struct SPKIPinningTests {
    static let agent = certificate(
        [
            "MIIBfjCCASWgAwIBAgIUEgXWVBILYRgwzVeLyLCesbN1lDowCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKcHVsc2UtdGVzdDAe",
            "Fw0yNjExMTgxOTEzMzBaFw0zNjExMTUxOTEzMzBaMBUxEzARBgNVBAMMCnB1bHNlLXRlc3QwWTATBgcqhkjOPQIBBggqhkjO",
            "PQMBBwNCAASPt1NBqzwz1PxxN5YwvoaPgcNvaqX091rjjoe5gJDBvL2wjDTyij0Cy/hICVkkFaRX3AjbVZqSvft9z8E74C0W",
            "o1MwUTAdBgNVHQ4EFgQUPuPM1nmZcC3UamEe9nsugZyl9hAwHwYDVR0jBBgwFoAUPuPM1nmZcC3UamEe9nsugZyl9hAwDwYD",
            "VR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiBlE4A+X1fvxMR1vjB3KXv0jms0+o80mWKTNZbSvhL5MgIgHa0juGsu",
            "PJ6F03zjDwv2UqZvpag2GFYFwNyTjJbQMro=",
        ].joined()
    )
    static let agentPin = "pH1hjnUWYFi4Rf54IdWL7qHp4w-jbMskG8KSXe4xxac"

    static let impostor = certificate(
        [
            "MIIBdTCCARugAwIBAgIUFU1w+d7LTN5QJX+2zoJqGRlZH0UwCgYIKoZIzj0EAwIwEDEOMAwGA1UEAwwFb3RoZXIwHhcNMjYx",
            "MTE4MTkxMzMwWhcNMzYxMTE1MTkxMzMwWjAQMQ4wDAYDVQQDDAVvdGhlcjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABCU8",
            "7kJ5bazxOuCPp4XN+vZmsm9Qe3cEce+TpOm3Ln29ZMa9rbv0uPlzMObT2hNIIoHKPfPSSUPrMr11dWzLhDOjUzBRMB0GA1Ud",
            "DgQWBBTqnBI4Et+lhTAGKcrnDyZ3YZ+gbzAfBgNVHSMEGDAWgBTqnBI4Et+lhTAGKcrnDyZ3YZ+gbzAPBgNVHRMBAf8EBTAD",
            "AQH/MAoGCCqGSM49BAMCA0gAMEUCIQC+knsytH4zIfQL58IkL61tLLHJqUaAn06uT+Sch+fy3AIgNXcKLOyWYVaR4tL1jn0J",
            "rNXSxEquObnsNCUAeEq5iWs=",
        ].joined()
    )
    static let impostorPin = "woAjcpt8ot4Ift2SQbwH9I5ZwokWFZqUUDaPnryqwPE"

    @Test func fingerprintMatchesOpenSSL() {
        #expect(SPKIFingerprint.of(Self.agent) == Self.agentPin)
        #expect(SPKIFingerprint.of(Self.impostor) == Self.impostorPin)
    }

    @Test func acceptsOnlyThePinnedKey() throws {
        #expect(PinningDelegate.matches(try trust(Self.agent), pin: Self.agentPin))
        #expect(!PinningDelegate.matches(try trust(Self.impostor), pin: Self.agentPin))
        #expect(!PinningDelegate.matches(try trust(Self.agent), pin: ""))
    }

    private static func certificate(_ base64: String) -> SecCertificate {
        guard let der = Data(base64Encoded: base64),
            let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else {
            fatalError("test certificate does not parse")
        }
        return certificate
    }

    private func trust(_ certificate: SecCertificate) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }
}
