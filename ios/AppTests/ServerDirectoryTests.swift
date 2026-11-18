import AgentKit
import Foundation
import Persistence
import Testing

@testable import Pulse

@MainActor @Suite struct ServerDirectoryTests {
    @Test func demoServerAppearsOnlyInDemoMode() {
        #expect(ServerDirectory.entries(records: [], demoEnabled: false).isEmpty)
        let entries = ServerDirectory.entries(records: [], demoEnabled: true)
        #expect(entries.map(\.id) == [ServerDirectory.demoServerId])
        #expect(entries.map(\.isDemo) == [true])
    }

    @Test func pairedServersComeFirstInUserOrder() {
        let second = ServerRecord(name: "db", host: "10.0.0.2", sortOrder: 1)
        let first = ServerRecord(name: "web", host: "web.example.com", port: 8443, sortOrder: 0)
        let entries = ServerDirectory.entries(records: [second, first], demoEnabled: true)
        #expect(entries.map(\.name) == ["web", "db", ServerDirectory.demoServer.name])
        #expect(entries.first?.endpoint == URL(string: "https://web.example.com:8443"))
        #expect(entries.first?.isDemo == false)
    }

    @Test func forcedDemoWinsOverSettings() throws {
        let environment = AppEnvironment(
            container: try PulseStore.makeContainer(inMemory: true),
            secrets: InMemorySecretStore(),
            launchedInDemo: true
        )
        #expect(environment.isDemoEnabled(settings: AppSettings(demoModeEnabled: false)))
    }

    @Test func settingsEnableDemoWithoutLaunchArgument() throws {
        let environment = AppEnvironment(
            container: try PulseStore.makeContainer(inMemory: true),
            secrets: InMemorySecretStore(),
            launchedInDemo: false
        )
        #expect(!environment.isDemoEnabled(settings: nil))
        #expect(environment.isDemoEnabled(settings: AppSettings(demoModeEnabled: true)))
    }

    @Test func demoServerRunsOnSeedDataWithoutNetwork() async throws {
        let environment = AppEnvironment(
            container: try PulseStore.makeContainer(inMemory: true),
            secrets: InMemorySecretStore(),
            launchedInDemo: true
        )
        let context = environment.makeContext(for: ServerDirectory.demoServer)
        await context.connect()
        #expect(context.connection == .connected)
        #expect(context.info?.hostname == "demo")
    }
}
