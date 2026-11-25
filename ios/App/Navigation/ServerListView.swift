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
    @State private var status: ServerStatusModel?
    @State private var deletion: ServerDeletion?

    private var entries: [ServerEntry] {
        ServerDirectory.entries(records: records, demoEnabled: environment.isDemoEnabled(settings: settings.first))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) { rows }
                .navigationTitle("Servers")
                .task(id: entries.map(\.id)) {
                    let status = self.status ?? environment.makeStatusModel()
                    self.status = status
                    await status.run(entries.map(\.id))
                }
                .serverDeletion($deletion, environment: environment) { id in
                    status?.remove(id)
                    if selection == id { selection = nil }
                }
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
                    if !records.isEmpty {
                        ToolbarItem(placement: .topBarLeading) { EditButton() }
                    }
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

    private var rows: some View {
        ForEach(entries) { entry in
            NavigationLink(value: entry.id) {
                ServerRow(name: entry.name, isDemo: entry.isDemo, status: status?.status(for: entry.id) ?? .init())
            }
            .moveDisabled(entry.isDemo)
            .swipeActions {
                // Neither onDelete nor a destructive role: both make List drop the row at once,
                // while deletion asks first and may fail, and the mismatch crashes UICollectionView.
                if !entry.isDemo {
                    Button(String(localized: "Delete"), systemImage: "trash") {
                        deletion = ServerDeletion(entry: entry)
                    }
                    .tint(DS.Palette.critical)
                }
            }
        }
        .onMove { source, destination in
            ServerOrder.move(records, from: source, to: destination)
            try? modelContext.save()
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
