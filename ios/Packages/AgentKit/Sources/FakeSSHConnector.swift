import Foundation

/// `SSHConnector` without a network: demo mode, previews and the install flow's tests.
/// Commands come from `script`; a command the script does not know stops the test.
public struct FakeSSHConnector: SSHConnector {
    public typealias Script = @Sendable (_ command: String) -> SSHOutput?

    /// The host key every fake server presents: a fixed Ed25519 key that guards nothing.
    public static let hostKey = SSHPublicKey(
        algorithm: "ssh-ed25519",
        blob: Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIHB1bHNlLWRlbW8tZmFrZS1zc2gtaG9zdC1rZXktMDAx") ?? Data())

    public let journal = FakeSSHJournal()
    private let password: String
    private let presentedKey: SSHPublicKey
    private let unreachable: Bool
    private let script: Script

    /// - Parameters:
    ///   - password: the one password the server accepts; any key login succeeds.
    ///   - unreachable: every call fails with `.unreachable`.
    public init(
        password: String = "demo", hostKey: SSHPublicKey = Self.hostKey, unreachable: Bool = false,
        script: @escaping Script
    ) {
        self.password = password
        presentedKey = hostKey
        self.unreachable = unreachable
        self.script = script
    }

    public func hostKey(host: String, port: Int) async throws(SSHError) -> SSHPublicKey {
        if unreachable { throw .unreachable }
        return presentedKey
    }

    public func connect(
        host: String, port: Int, user: String, auth: SSHAuth, trusting key: SSHPublicKey
    ) async throws(SSHError) -> any SSHSession {
        if unreachable { throw .unreachable }
        guard key == presentedKey else { throw .hostKeyMismatch(presented: presentedKey) }
        if case .password(let given) = auth.method, given != password { throw .authenticationFailed }
        return Session(user: user, journal: journal, script: script)
    }

    struct Session: SSHSession {
        let user: String
        let journal: FakeSSHJournal
        let script: Script

        func run(_ command: String, stdinLine: String?) async throws(SSHError) -> SSHOutput {
            await journal.append(.init(user: user, command: command, stdinLine: stdinLine))
            guard let output = script(command) else {
                preconditionFailure("FakeSSHConnector has no output for `\(command)`")
            }
            return output
        }

        func close() async {}
    }
}

/// What ran on a fake server, in order.
public actor FakeSSHJournal {
    public struct Entry: Sendable, Equatable {
        public let user: String
        public let command: String
        public let stdinLine: String?

        public init(user: String, command: String, stdinLine: String?) {
            self.user = user
            self.command = command
            self.stdinLine = stdinLine
        }
    }

    public private(set) var commands: [Entry] = []

    func append(_ entry: Entry) {
        commands.append(entry)
    }
}
