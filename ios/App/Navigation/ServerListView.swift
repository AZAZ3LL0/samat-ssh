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
    /// The open add sheet; `item:` hands it the link, which `isPresented:` would capture stale.
    @State private var addRequest: AddServerRequest?

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
                    Button(String(localized: "Add server"), systemImage: "plus") {
                        addRequest = AddServerRequest(link: nil)
                    }
                }
                #if DEBUG
                    ToolbarItem(placement: .topBarTrailing) { DebugMenu() }
                #endif
            }
            .sheet(item: $addRequest, content: addServerSheet)
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
        .onOpenURL { url in
            addRequest = AddServerRequest(link: url)
        }
        .onChange(of: selection) { _, id in
            try? AppSettings.current(in: modelContext).lastSelectedServerId = id
        }
    }

    private func addServerSheet(_ request: AddServerRequest) -> some View {
        AddServerView(
            model: environment.makeAddServerModel(deviceName: UIDevice.current.name), link: request.link,
            makeSSHInstall: { environment.makeSSHInstallModel(deviceName: UIDevice.current.name) },
            onPaired: { id in selection = id }
        )
    }

    private func enableDemo() {
        try? AppSettings.current(in: modelContext).demoModeEnabled = true
    }
}

/// What opened the add sheet: the + button, or a `pulse://pair` link from a QR code or another app.
private struct AddServerRequest: Identifiable {
    let id = UUID()
    let link: URL?
}
