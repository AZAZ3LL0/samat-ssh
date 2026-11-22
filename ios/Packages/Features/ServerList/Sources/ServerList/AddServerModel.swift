import AgentKit
import Foundation
import Observation
import Persistence
import SwiftData
import os

/// Adding a server by hand: address, the agent's key checked by the user, pairing code.
@Observable @MainActor public final class AddServerModel {
    public enum Step: Equatable {
        /// Host and port form.
        case address
        /// The agent answered; the user compares its fingerprint with `pulse-agent pair`.
        case verify(AgentProbe)
        /// The user confirmed the key; waiting for the pairing code.
        case code(AgentProbe)
        /// The server is saved under this id.
        case paired(UUID)
    }

    /// Core version that introduced `GET /v1/info` and `POST /v1/pair`, all this flow needs.
    public static let requiredApiVersion = 1
    public static let defaultPort = 7443
    /// `PairRequest.deviceName` maxLength in the contract.
    static let deviceNameLimit = 64

    public var host = ""
    public var port = String(defaultPort)
    public var name = ""
    public var code = ""
    public private(set) var step: Step = .address
    public private(set) var isWorking = false
    public private(set) var error: AgentError?
    /// The Keychain or the cache refused to save; nothing was stored.
    public private(set) var saveFailed = false
    /// The last scanned or opened link is not a `pulse://pair` link from `pulse-agent pair`.
    public private(set) var invalidLink = false

    private let pairing: any AgentPairing
    private let secrets: any SecretStore
    private let context: ModelContext
    private let deviceName: String
    private let logger = Logger(subsystem: "dev.azaz3ll0.pulse", category: "servers")

    public init(pairing: any AgentPairing, secrets: any SecretStore, context: ModelContext, deviceName: String) {
        self.pairing = pairing
        self.secrets = secrets
        self.context = context
        self.deviceName = String(deviceName.prefix(Self.deviceNameLimit))
    }

    /// `https://<host>:<port>`, or `nil` while the form holds something that is not one.
    public var endpoint: URL? {
        guard let host = Self.normalizedHost(host), let port = Int(port), (1...65535).contains(port) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }

    public var canConnect: Bool { endpoint != nil && !isWorking }
    public var canPair: Bool { !normalizedCode.isEmpty && !isWorking }

    public func connect() async {
        guard let endpoint, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        do throws(AgentError) {
            let probe = try await pairing.probe(endpoint)
            try AgentCompatibility.check(probe.info, requiredApiVersion: Self.requiredApiVersion)
            step = .verify(probe)
        } catch {
            self.error = error
        }
    }

    /// A scanned QR code or a deep link. The link carries the fingerprint `pulse-agent pair` printed,
    /// so it replaces the user's manual check; the agent must still present exactly that key.
    /// Ends on the code step: pairing waits for a tap, so a link from a web page adds nothing by itself.
    public func open(_ url: URL) async {
        guard !isWorking else { return }
        error = nil
        saveFailed = false
        guard let link = PairingLink(url: url) else {
            invalidLink = true
            return
        }
        invalidLink = false
        host = link.host
        port = String(link.port)
        code = ""
        step = .address
        isWorking = true
        defer { isWorking = false }
        do throws(AgentError) {
            let probe = try await pairing.probe(link.endpoint)
            guard probe.fingerprint == link.fingerprint else { throw .pinMismatch }
            try AgentCompatibility.check(probe.info, requiredApiVersion: Self.requiredApiVersion)
            code = link.code
            step = .verify(probe)
            confirmFingerprint()
        } catch {
            self.error = error
        }
    }

    /// The text of a scanned QR code; one that is not a URL is no pairing link either.
    public func openScanned(_ payload: String) async {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = nil
            invalidLink = true
            return
        }
        await open(url)
    }

    public func confirmFingerprint() {
        guard case .verify(let probe) = step else { return }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = existingRecord()?.name ?? probe.info.hostname
        }
        step = .code(probe)
    }

    /// The keys differ: someone may sit between the phone and the server, so nothing is kept.
    public func rejectFingerprint() {
        code = ""
        step = .address
    }

    public func pair() async {
        guard case .code(let probe) = step, let endpoint, let host = Self.normalizedHost(host), canPair else {
            return
        }
        isWorking = true
        defer { isWorking = false }
        error = nil
        saveFailed = false
        let response: PairResponse
        do throws(AgentError) {
            response = try await pairing.pair(
                endpoint, pin: probe.fingerprint, code: normalizedCode, deviceName: deviceName)
        } catch {
            self.error = error
            // The agent no longer presents the confirmed key: start over with a fresh check.
            if error == .pinMismatch { step = .address }
            return
        }
        do {
            step = .paired(try save(probe: probe, host: host, port: endpoint.port ?? Self.defaultPort, token: response))
        } catch {
            logger.error("cannot save paired server: \(String(describing: error), privacy: .public)")
            saveFailed = true
        }
    }

    /// Secrets first, record last: `AppEnvironment` reads secrets only for an existing record.
    private func save(probe: AgentProbe, host: String, port: Int, token: PairResponse) throws -> UUID {
        let existing = existingRecord()
        let id = existing?.id ?? UUID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.write(Data(probe.fingerprint.utf8), for: .spki(id))
            try secrets.write(Data(token.token.utf8), for: .token(id))
            let record: ServerRecord
            if let existing {
                record = existing
            } else {
                record = ServerRecord(id: id, name: "", host: host, port: port, sortOrder: try nextSortOrder())
            }
            record.name = trimmedName.isEmpty ? probe.info.hostname : trimmedName
            record.lastSeenAt = .now
            record.lastApiVersion = probe.info.apiVersion
            if existing == nil { context.insert(record) }
            try context.save()
            return id
        } catch {
            // A re-paired server keeps the new secrets: the old token and pin no longer work anyway.
            if existing == nil {
                try? secrets.delete(.spki(id))
                try? secrets.delete(.token(id))
            }
            context.rollback()
            throw error
        }
    }

    private func existingRecord() -> ServerRecord? {
        guard let host = Self.normalizedHost(host), let port = Int(port) else { return nil }
        let descriptor = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.host == host && $0.port == port })
        return try? context.fetch(descriptor).first
    }

    private func nextSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<ServerRecord>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try context.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }

    /// The agent ignores case and spaces of a typed code; codes never contain spaces.
    private var normalizedCode: String {
        code.filter { !$0.isWhitespace }.uppercased()
    }

    /// A DNS name, IPv4 or IPv6 address; IPv6 comes back in brackets, the form URLs and records use.
    nonisolated static func normalizedHost(_ raw: String) -> String? {
        let host = raw.trimmingCharacters(in: .whitespaces)
        if host.contains(":") {
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
            guard bare.contains(":"), bare.unicodeScalars.allSatisfy(hex.contains) else { return nil }
            return "[\(bare)]"
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return host
    }
}
