import Foundation
import Security
import os

/// A Keychain account. The fixed set of names keeps every secret the app stores
/// discoverable in one place.
public struct KeychainAccount: Hashable, Sendable {
    public let rawValue: String

    /// Bearer token of the agent.
    public static func token(_ serverId: UUID) -> Self { Self(rawValue: "token.\(serverId.uuidString)") }
    /// SHA-256 of the agent's SPKI, base64url.
    public static func spki(_ serverId: UUID) -> Self { Self(rawValue: "spki.\(serverId.uuidString)") }
    /// Ed25519 private key generated in the app for SSH.
    public static func sshKey(_ serverId: UUID) -> Self { Self(rawValue: "ssh.key.\(serverId.uuidString)") }
    /// The SSH host key the user confirmed, as an OpenSSH public key line (docs/adr/0001).
    public static func sshHostKey(_ serverId: UUID) -> Self {
        Self(rawValue: "ssh.hostkey.\(serverId.uuidString)")
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
}

/// Secrets storage. The only place the app keeps tokens, pins and keys.
public protocol SecretStore: Sendable {
    func read(_ account: KeychainAccount) throws(KeychainError) -> Data?
    func write(_ data: Data, for account: KeychainAccount) throws(KeychainError)
    func delete(_ account: KeychainAccount) throws(KeychainError)
}

/// The system Keychain: this device only, available after first unlock so
/// background refresh works, never synced to iCloud.
public struct Keychain: SecretStore {
    public static let service = "dev.azaz3ll0.pulse"

    public init() {}

    public func read(_ account: KeychainAccount) throws(KeychainError) -> Data? {
        var query = Self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case let status: throw .status(status)
        }
    }

    public func write(_ data: Data, for account: KeychainAccount) throws(KeychainError) {
        var attributes: [String: Any] = [kSecValueData as String: data]
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemUpdate(Self.query(account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let insert = Self.query(account).merging(attributes) { _, new in new }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw .status(added) }
        default:
            throw .status(status)
        }
    }

    public func delete(_ account: KeychainAccount) throws(KeychainError) {
        let status = SecItemDelete(Self.query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .status(status) }
    }

    /// Identifies an item. Every call goes through it, so no item can land
    /// outside the service or become synchronizable.
    static func query(_ account: KeychainAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// A `SecretStore` that keeps secrets in memory, for tests, previews and demo mode.
public final class InMemorySecretStore: SecretStore {
    private let items = OSAllocatedUnfairLock(initialState: [KeychainAccount: Data]())

    public init() {}

    public func read(_ account: KeychainAccount) -> Data? {
        items.withLock { $0[account] }
    }

    public func write(_ data: Data, for account: KeychainAccount) {
        items.withLock { $0[account] = data }
    }

    public func delete(_ account: KeychainAccount) {
        _ = items.withLock { $0.removeValue(forKey: account) }
    }
}
