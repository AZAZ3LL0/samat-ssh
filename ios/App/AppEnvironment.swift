import AgentKit
import Foundation
import Observation
import Persistence
import ServerList
import SwiftData

/// Composition root: the only place that builds stores and clients. Views reach it through
/// `@Environment`; features get a `ServerContext` and nothing else.
@Observable @MainActor final class AppEnvironment {
    let container: ModelContainer
    let secrets: any SecretStore
    /// Demo mode forced by the launch argument `-PulseDemo YES` or the Demo build configuration.
    let launchedInDemo: Bool
    /// A forced demo pairs with the fake agent at any address, so adding a server works offline.
    let pairing: any AgentPairing
    /// A forced demo installs on a fake server, so "Install over SSH" works offline too.
    let sshConnector: any SSHConnector

    init(container: ModelContainer, secrets: any SecretStore, launchedInDemo: Bool) {
        self.container = container
        self.secrets = secrets
        self.launchedInDemo = launchedInDemo
        self.pairing = launchedInDemo ? FakeAgentPairing() : LiveAgentPairing()
        self.sshConnector = launchedInDemo ? DemoSSHServer.connector() : LiveSSHConnector()
    }

    /// Picks stores for this launch. A forced demo keeps everything in memory, so App Review
    /// and UI tests always start from the same seed and never touch the Keychain.
    static func live(arguments: UserDefaults = .standard) throws -> AppEnvironment {
        var demo = arguments.bool(forKey: "PulseDemo")
        #if PULSE_DEMO
            demo = true
        #endif
        return AppEnvironment(
            container: try PulseStore.makeContainer(inMemory: demo),
            secrets: demo ? InMemorySecretStore() : Keychain(),
            launchedInDemo: demo
        )
    }

    func isDemoEnabled(settings: AppSettings?) -> Bool {
        launchedInDemo || settings?.demoModeEnabled == true
    }

    func makeContext(for entry: ServerEntry) -> ServerContext {
        ServerContext(serverId: entry.id, client: makeClient(for: entry))
    }

    func makeClient(for entry: ServerEntry) -> any AgentClient {
        // Servers added in a forced demo were paired with the fake agent; they stay on it.
        guard let endpoint = entry.endpoint, !launchedInDemo else { return FakeAgentClient() }
        let pin = (try? secrets.read(.spki(entry.id))).flatMap { String(data: $0, encoding: .utf8) }
        let token = (try? secrets.read(.token(entry.id))).flatMap { String(data: $0, encoding: .utf8) }
        // Pairing stores the pin before the record exists; an empty pin matches no certificate,
        // so a record without one fails as pinMismatch and asks for pairing again.
        return LiveAgentClient(baseURL: endpoint, pin: pin ?? "", token: token)
    }

    /// The client of a server by id, for models that outlive one list of entries.
    func makeClient(serverId: UUID) -> any AgentClient {
        let records = (try? container.mainContext.fetch(FetchDescriptor<ServerRecord>())) ?? []
        let entry = ServerDirectory.entries(records: records, demoEnabled: true).first { $0.id == serverId }
        return makeClient(for: entry ?? ServerDirectory.demoServer)
    }

    func makeStatusModel() -> ServerStatusModel {
        ServerStatusModel(context: container.mainContext) { [unowned self] id in makeClient(serverId: id) }
    }

    func makeRemover() -> ServerRemover {
        ServerRemover(secrets: secrets, context: container.mainContext)
    }

    func makeAddServerModel(deviceName: String) -> AddServerModel {
        AddServerModel(pairing: pairing, secrets: secrets, context: container.mainContext, deviceName: deviceName)
    }

    func makeSSHInstallModel(deviceName: String) -> SSHInstallModel {
        SSHInstallModel(
            connector: sshConnector, pairing: pairing, secrets: secrets, context: container.mainContext,
            deviceName: deviceName)
    }
}
