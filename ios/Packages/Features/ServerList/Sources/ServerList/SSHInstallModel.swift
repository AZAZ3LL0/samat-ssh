import AgentKit
import Foundation
import Observation
import Persistence
import SwiftData
import os

/// What stopped an SSH install. The SSH password never appears in any case.
public enum SSHInstallError: Error, Equatable, Sendable {
    case ssh(SSHError)
    case agent(AgentError)
    /// `uname -m` names a machine the agent has no build for.
    case unsupportedArchitecture(String)
    /// The login user is not root and `sudo` refused the password.
    case sudoRefused
    /// A key login can become root only through passwordless sudo (docs/adr/0001).
    case keyNeedsPasswordlessSudo
    /// A command on the server failed; the last line of its stderr.
    case commandFailed(String)
    /// `pulse-agent pair --json` printed something else.
    case invalidPairOutput
    /// The Keychain or the cache refused to save; nothing was stored.
    case saveFailed
}

/// What the preflight learned about the server, shown before anything is installed.
public struct ServerFacts: Equatable, Sendable {
    /// The release archive's arch: `amd64` or `arm64`.
    public let architecture: String
    /// `PRETTY_NAME` of `/etc/os-release`.
    public let systemName: String
    /// Ubuntu 22.04/24.04 or Debian 12 (tech.md 3); any other system is best effort.
    public let supportedSystem: Bool
    /// The login user is not root, so commands run through sudo.
    public let viaSudo: Bool
}

/// Installing the agent over SSH and pairing with it (S1.3, docs/adr/0001).
@Observable @MainActor public final class SSHInstallModel {
    public enum Step: Equatable {
        case form
        /// The server's host key, for the user to compare before any credential is sent.
        case hostKey(SSHPublicKey)
        /// Logged in and checked; waiting for the user to start the install.
        case ready(ServerFacts)
        /// The server is saved under this id.
        case paired(UUID)
    }

    public enum Phase: Equatable, Sendable {
        case connecting, checking, installing, authorizing, pairing
    }

    /// How a command becomes root.
    private enum Elevation {
        case root
        /// `sudo -S`: the password goes to stdin, never into the command line.
        case sudoPassword(String)
        case sudoPasswordless
    }

    public static let defaultPort = 22

    public var host = ""
    public var port = String(defaultPort)
    public var user = "root"
    /// Used for the login and sudo of this install only; cleared when it ends.
    public var password = ""
    /// A pasted OpenSSH private key; when set, it logs in instead of the password.
    public var privateKey = ""
    public var passphrase = ""
    public private(set) var step: Step = .form
    public private(set) var phase: Phase?
    public private(set) var error: SSHInstallError?

    private let connector: any SSHConnector
    private let pairing: any AgentPairing
    private let saver: ServerSaver
    private let deviceName: String
    let installScript: String?
    private var auth: SSHAuth?
    private var session: (any SSHSession)?
    /// The host key the user confirmed and the session trusts.
    private var hostKey: SSHPublicKey?
    private var elevation = Elevation.root
    private let logger = Logger(subsystem: "dev.azaz3ll0.pulse", category: "servers")

    public convenience init(
        connector: any SSHConnector, pairing: any AgentPairing, secrets: any SecretStore, context: ModelContext,
        deviceName: String
    ) {
        let script = Bundle.module.url(forResource: "install", withExtension: "sh")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        self.init(
            connector: connector, pairing: pairing, secrets: secrets, context: context, deviceName: deviceName,
            installScript: script)
    }

    init(
        connector: any SSHConnector, pairing: any AgentPairing, secrets: any SecretStore, context: ModelContext,
        deviceName: String, installScript: String?
    ) {
        self.connector = connector
        self.pairing = pairing
        saver = ServerSaver(secrets: secrets, context: context)
        self.deviceName = String(deviceName.prefix(AddServerModel.deviceNameLimit))
        self.installScript = installScript
    }

    public var isWorking: Bool { phase != nil }

    public var canConnect: Bool {
        sshHost != nil && sshPort != nil && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && !(password.isEmpty && privateKey.isEmpty) && !isWorking
    }

    private var sshHost: String? { AddServerModel.normalizedHost(host) }
    private var sshPort: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var login: String { user.trimmingCharacters(in: .whitespaces) }

    /// Reads the host key without logging in. A pasted key that cannot be read fails here, before the network.
    public func readHostKey() async {
        guard canConnect, let sshHost, let sshPort else { return }
        error = nil
        phase = .connecting
        defer { phase = nil }
        do throws(SSHError) {
            if privateKey.isEmpty {
                auth = .password(password)
            } else {
                auth = try .privateKey(openSSH: privateKey, passphrase: passphrase.isEmpty ? nil : passphrase)
            }
            step = .hostKey(try await connector.hostKey(host: sshHost, port: sshPort))
        } catch {
            self.error = .ssh(error)
        }
    }

    /// The fingerprints differ: nothing is sent to that server.
    public func rejectHostKey() {
        auth = nil
        step = .form
    }

    /// Logs in trusting exactly the confirmed key, then checks arch, distro and root access.
    public func trustHostKey() async {
        guard case .hostKey(let key) = step, let auth, let sshHost, let sshPort else { return }
        error = nil
        phase = .connecting
        defer { phase = nil }
        do throws(SSHInstallError) {
            let session: any SSHSession
            do throws(SSHError) {
                session = try await connector.connect(
                    host: sshHost, port: sshPort, user: login, auth: auth, trusting: key)
            } catch {
                throw .ssh(error)
            }
            self.session = session
            hostKey = key
            phase = .checking
            step = .ready(try await preflight(session))
            logger.info("ssh preflight passed")
        } catch {
            logger.error("ssh preflight stopped")
            self.error = error
            await close()
            step = .form
        }
    }

    public func install() async {
        guard case .ready = step, let session, let hostKey, let sshHost, let sshPort, !isWorking else { return }
        error = nil
        defer { phase = nil }
        do throws(SSHInstallError) {
            guard let installScript else { throw .commandFailed("install.sh is missing from the app") }
            phase = .installing
            try await runChecked(session, elevated(Self.scriptCommand(installScript)))
            phase = .authorizing
            let key = saver.sshKey(sshHost: sshHost, user: login) ?? .generate()
            try await runChecked(session, Self.authorizeCommand(key.authorizedKeysLine(comment: "pulse-\(deviceName)")))
            phase = .pairing
            let output = try await runChecked(session, elevated("/usr/local/bin/pulse-agent pair --json"))
            let id = try await pair(output, key: key, hostKey: hostKey, sshHost: sshHost, sshPort: sshPort)
            logger.info("agent installed over ssh and paired")
            await close()
            password = ""
            step = .paired(id)
        } catch {
            logger.error("ssh install stopped")
            self.error = error
            // A dropped connection cannot run the retry; start over from the form.
            if case .ssh = error {
                await close()
                step = .form
            }
        }
    }

    /// Leaving the screen ends the session and forgets the password.
    public func cancel() async {
        await close()
        password = ""
        step = .form
    }

    private func close() async {
        await session?.close()
        session = nil
        auth = nil
        hostKey = nil
    }

    private func preflight(_ session: any SSHSession) async throws(SSHInstallError) -> ServerFacts {
        let machine = try await runChecked(session, "uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let architecture = Self.architecture(machine) else { throw .unsupportedArchitecture(machine) }
        let osRelease = Self.osRelease(try await run(session, "cat /etc/os-release").stdout)
        let uid = try await runChecked(session, "id -u").trimmingCharacters(in: .whitespacesAndNewlines)
        if uid == "0" {
            elevation = .root
        } else if privateKey.isEmpty {
            guard try await run(session, "sudo -S -p '' true", stdinLine: password).status == 0 else {
                throw .sudoRefused
            }
            elevation = .sudoPassword(password)
        } else {
            guard try await run(session, "sudo -n true").status == 0 else { throw .keyNeedsPasswordlessSudo }
            elevation = .sudoPasswordless
        }
        let id = osRelease["ID"] ?? ""
        let version = osRelease["VERSION_ID"] ?? ""
        return ServerFacts(
            architecture: architecture,
            systemName: osRelease["PRETTY_NAME"] ?? "Linux",
            supportedSystem: Self.supportedSystems.contains("\(id) \(version)"),
            viaSudo: uid != "0")
    }

    private func pair(
        _ output: String, key: SSHKeyPair, hostKey: SSHPublicKey, sshHost: String, sshPort: Int
    ) async throws(SSHInstallError) -> UUID {
        guard let data = output.data(using: .utf8), let info = try? JSONDecoder().decode(PairOutput.self, from: data),
            (1...65535).contains(info.port)
        else { throw .invalidPairOutput }
        var components = URLComponents()
        components.scheme = "https"
        components.host = sshHost
        components.port = info.port
        guard let endpoint = components.url else { throw .invalidPairOutput }
        let response: PairResponse
        let probe: AgentProbe
        do throws(AgentError) {
            probe = try await pairing.probe(endpoint)
            // The agent must present the key `pair` printed over the trusted SSH channel.
            guard probe.fingerprint == info.fingerprint else { throw .pinMismatch }
            try AgentCompatibility.check(probe.info, requiredApiVersion: AddServerModel.requiredApiVersion)
            response = try await pairing.pair(endpoint, pin: info.fingerprint, code: info.code, deviceName: deviceName)
        } catch {
            throw .agent(error)
        }
        do {
            let ssh = SSHCredentials(host: sshHost, port: sshPort, user: login, key: key, hostKey: hostKey)
            return try saver.save(host: sshHost, port: info.port, name: "", probe: probe, token: response, ssh: ssh)
        } catch {
            logger.error("cannot save installed server: \(String(describing: error), privacy: .public)")
            throw .saveFailed
        }
    }

    private func elevated(_ command: String) -> String {
        switch elevation {
        case .root: command
        case .sudoPassword: "sudo -S -p '' \(command)"
        case .sudoPasswordless: "sudo -n \(command)"
        }
    }

    private var stdinLine: String? {
        if case .sudoPassword(let password) = elevation { password } else { nil }
    }

    /// Runs `command` and returns stdout; a non-zero exit fails with the last line of stderr.
    @discardableResult
    private func runChecked(_ session: any SSHSession, _ command: String) async throws(SSHInstallError) -> String {
        let output = try await run(session, command, stdinLine: command.hasPrefix("sudo -S") ? stdinLine : nil)
        guard output.status == 0 else {
            let lines = output.stderr.split(whereSeparator: \.isNewline)
            throw .commandFailed(lines.last.map(String.init) ?? "exit status \(output.status)")
        }
        return output.stdout
    }

    private func run(
        _ session: any SSHSession, _ command: String, stdinLine: String? = nil
    ) async throws(SSHInstallError) -> SSHOutput {
        do throws(SSHError) {
            return try await session.run(command, stdinLine: stdinLine)
        } catch {
            throw .ssh(error)
        }
    }
}

extension SSHInstallModel {
    static let supportedSystems: Set<String> = ["ubuntu 22.04", "ubuntu 24.04", "debian 12"]

    /// `uname -m` to the arch of the release archives, as `install.sh` maps it.
    nonisolated static func architecture(_ machine: String) -> String? {
        switch machine {
        case "x86_64", "amd64": "amd64"
        case "aarch64", "arm64": "arm64"
        default: nil
        }
    }

    /// `KEY=value` and `KEY="value"` lines of `/etc/os-release`.
    nonisolated static func osRelease(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return fields
    }

    /// Stdin stays open for `sudo -S`, so the script travels inside the command, as base64 that needs no quoting.
    nonisolated static func scriptCommand(_ script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        let run = #"t=$(mktemp) && printf %s \#(encoded) | base64 -d > "$t" && sh "$t"; s=$?; rm -f "$t"; exit $s"#
        return "sh -c '\(run)'"
    }

    /// Appends `line` unless it is already there. `line` holds only base64 and `authorizedKeysLine`'s safe
    /// characters, so single quotes keep it literal.
    nonisolated static func authorizeCommand(_ line: String) -> String {
        "umask 077 && mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys"
            + " && chmod 600 ~/.ssh/authorized_keys"
            + " && { grep -qxF '\(line)' ~/.ssh/authorized_keys || echo '\(line)' >> ~/.ssh/authorized_keys; }"
    }
}

/// `pulse-agent pair --json` (agent/cmd/pulse-agent/pair.go).
private struct PairOutput: Decodable {
    let port: Int
    let fingerprint: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case port, code
        case fingerprint = "fp"
    }
}
