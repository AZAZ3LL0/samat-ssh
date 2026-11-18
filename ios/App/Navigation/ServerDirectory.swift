import Foundation
import Persistence

/// A row of the server list: a paired server or the built-in demo server.
struct ServerEntry: Identifiable, Hashable {
    let id: UUID
    let name: String
    /// `https://<host>:<port>` of the agent; `nil` for the demo server, which runs on fixtures.
    let endpoint: URL?

    var isDemo: Bool { endpoint == nil }
}

enum ServerDirectory {
    /// Fixed so a selected demo server survives relaunches.
    static let demoServerId = UUID(uuidString: "00000000-0000-0000-0000-00000000DE70") ?? UUID()

    static var demoServer: ServerEntry {
        ServerEntry(id: demoServerId, name: String(localized: "Demo server"), endpoint: nil)
    }

    /// Paired servers in the user's order, then the demo server when demo mode is on.
    static func entries(records: [ServerRecord], demoEnabled: Bool) -> [ServerEntry] {
        let paired = records.sorted { $0.sortOrder < $1.sortOrder }.compactMap { record -> ServerEntry? in
            var components = URLComponents()
            components.scheme = "https"
            components.host = record.host
            components.port = record.port
            guard let url = components.url else { return nil }
            return ServerEntry(id: record.id, name: record.name, endpoint: url)
        }
        return demoEnabled ? paired + [demoServer] : paired
    }
}
