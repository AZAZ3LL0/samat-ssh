import Foundation
import Security
import Testing

@testable import Persistence

@Suite struct KeychainTests {
    @Test func namesAccountsPerServer() throws {
        let id = try #require(UUID(uuidString: "6F1C2A4E-0000-4000-8000-000000000001"))
        #expect(KeychainAccount.token(id).rawValue == "token.6F1C2A4E-0000-4000-8000-000000000001")
        #expect(KeychainAccount.spki(id).rawValue == "spki.6F1C2A4E-0000-4000-8000-000000000001")
        #expect(KeychainAccount.sshKey(id).rawValue == "ssh.key.6F1C2A4E-0000-4000-8000-000000000001")
        #expect(KeychainAccount.sshHostKey(id).rawValue == "ssh.hostkey.6F1C2A4E-0000-4000-8000-000000000001")
    }

    @Test func scopesItemsToTheAppServiceWithoutSync() {
        let query = Keychain.query(.token(UUID()))
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "dev.azaz3ll0.pulse")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func roundTripsInMemory() throws {
        try assertRoundTrip(InMemorySecretStore())
    }

    /// A hostless SwiftPM test bundle has no keychain entitlement in the
    /// simulator, so this runs only where the system grants access (app-hosted tests).
    @Test(.enabled(if: keychainAvailable(), "test bundle has no keychain entitlement"))
    func roundTripsInSystemKeychain() throws {
        try assertRoundTrip(Keychain())

        let account = KeychainAccount.spki(UUID())
        defer { try? Keychain().delete(account) }
        try Keychain().write(Data("pin".utf8), for: account)
        var query = Keychain.query(account)
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    private func assertRoundTrip(_ store: some SecretStore) throws {
        let server = UUID()
        defer {
            try? store.delete(.token(server))
            try? store.delete(.spki(server))
        }
        #expect(try store.read(.token(server)) == nil)
        try store.write(Data("first".utf8), for: .token(server))
        try store.write(Data("second".utf8), for: .token(server))
        try store.write(Data("pin".utf8), for: .spki(server))
        #expect(try store.read(.token(server)) == Data("second".utf8))
        #expect(try store.read(.spki(server)) == Data("pin".utf8))

        try store.delete(.token(server))
        #expect(try store.read(.token(server)) == nil)
        #expect(try store.read(.spki(server)) == Data("pin".utf8))
        try store.delete(.token(server))
    }
}

private func keychainAvailable() -> Bool {
    let account = KeychainAccount(rawValue: "probe.\(UUID().uuidString)")
    defer { try? Keychain().delete(account) }
    return (try? Keychain().write(Data(), for: account)) != nil
}
