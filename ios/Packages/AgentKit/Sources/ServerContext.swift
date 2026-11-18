import Foundation
import Observation

/// One open server: its client, connection state and `AgentInfo`. The app creates it when a
/// server screen opens and hands it to features through `@Environment`.
@Observable @MainActor public final class ServerContext {
    public let serverId: UUID
    public let client: any AgentClient
    public private(set) var connection: ConnectionState = .connecting
    /// Set even when the version gate fails, so the screen can name both versions.
    public private(set) var info: AgentInfo?
    public private(set) var error: AgentError?

    public init(serverId: UUID, client: any AgentClient) {
        self.serverId = serverId
        self.client = client
    }

    /// Fetches `AgentInfo` and checks the version gate (`tech.md` 6.1).
    public func connect() async {
        connection = .connecting
        error = nil
        do throws(AgentError) {
            let info = try await client.info()
            self.info = info
            try AgentCompatibility.check(info)
            connection = .connected
        } catch {
            self.error = error
            connection = .offline
        }
    }

    /// A tab or action needing `feature` stays hidden until the agent reports it.
    public func supports(_ feature: AgentFeature) -> Bool {
        info?.features.contains(feature) ?? false
    }
}
