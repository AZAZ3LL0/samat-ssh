import DesignSystem
import Persistence
import SwiftData
import SwiftUI

/// Root of the app: the server list, and the selected server next to it or pushed over it.
struct ServerListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [ServerRecord]
    @Query private var settings: [AppSettings]
    @State private var selection: ServerEntry.ID?

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
                        message: String(
                            localized: "Pairing a server comes in a later update. Try the demo server meanwhile."),
                        systemImage: "server.rack",
                        action: (title: String(localized: "Try demo"), run: enableDemo)
                    )
                }
            }
            #if DEBUG
                .toolbar { ToolbarItem(placement: .topBarTrailing) { DebugMenu() } }
            #endif
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
