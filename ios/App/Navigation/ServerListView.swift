import DesignSystem
import Persistence
import ServerList
import SwiftData
import SwiftUI

/// Root of the app: the server list, and the selected server next to it or pushed over it.
struct ServerListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [ServerRecord]
    @Query private var settings: [AppSettings]
    @State private var selection: ServerEntry.ID?
    @State private var isAddingServer = false

    private var entries: [ServerEntry] {
        ServerDirectory.entries(records: records, demoEnabled: environment.isDemoEnabled(settings: settings.first))
    }

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                NavigationLink(value: entry.id) {
                    Label(entry.name, systemImage: entry.isDemo ? "sparkles" : "server.rack")
                }
            }
            .navigationTitle("Servers")
            .overlay {
                if entries.isEmpty {
                    EmptyState(
                        title: String(localized: "No servers"),
                        // Release builds have no debug menu: this is the only switch for demo mode there.
                        message: String(localized: "Add a server with the + button, or try the demo server."),
                        systemImage: "server.rack",
                        action: (title: String(localized: "Try demo"), run: enableDemo)
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "Add server"), systemImage: "plus") { isAddingServer = true }
                }
                #if DEBUG
                    ToolbarItem(placement: .topBarTrailing) { DebugMenu() }
                #endif
            }
            .sheet(isPresented: $isAddingServer) {
                AddServerView(model: environment.makeAddServerModel(deviceName: UIDevice.current.name)) { id in
                    selection = id
                }
            }
        } detail: {
            if let entry = entries.first(where: { $0.id == selection }) {
                NavigationStack {
                    ServerScreen(entry: entry)
                }
                .id(entry.id)
            } else {
                EmptyState(title: String(localized: "Select a server"), systemImage: "sidebar.left")
            }
        }
        .onAppear {
            selection = settings.first?.lastSelectedServerId
        }
        .onChange(of: selection) { _, id in
            try? AppSettings.current(in: modelContext).lastSelectedServerId = id
        }
    }

    private func enableDemo() {
        try? AppSettings.current(in: modelContext).demoModeEnabled = true
    }
}
