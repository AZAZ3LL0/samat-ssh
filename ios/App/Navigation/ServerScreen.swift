import AgentKit
import DesignSystem
import SwiftUI

/// A server with its tabs from `ServerTabRegistry`, shown once the agent has answered `info`.
struct ServerScreen: View {
    let entry: ServerEntry
    /// Every server of the list, for the switcher in the header.
    let entries: [ServerEntry]
    let onSelect: (ServerEntry.ID) -> Void
    @Environment(AppEnvironment.self) private var environment
    /// Built once per server in `task`, not in `body`: a live client owns a URLSession.
    @State private var context: ServerContext?

    var body: some View {
        Group {
            if let context {
                content(context)
                    .environment(context)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { switcher }
            if let context {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionIndicator(state: context.connection)
                }
            }
        }
        .task(id: entry.id) {
            let context = environment.makeContext(for: entry)
            self.context = context
            await context.connect()
        }
    }

    /// Quick switch between servers without going back to the list.
    private var switcher: some View {
        Menu {
            ForEach(entries) { other in
                Button {
                    onSelect(other.id)
                } label: {
                    if other.id == entry.id {
                        Label(other.name, systemImage: "checkmark")
                    } else {
                        Text(other.name)
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text(entry.name).font(.headline)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .foregroundStyle(.primary)
        }
        .disabled(entries.count < 2)
        .accessibilityIdentifier("server.switcher")
    }

    @ViewBuilder private func content(_ context: ServerContext) -> some View {
        if let error = context.error {
            VStack {
                ErrorBanner(error: error) { Task { await context.connect() } }
                    .padding(DS.Spacing.l)
                Spacer()
            }
        } else if let info = context.info {
            TabView {
                ForEach(ServerTabRegistry.visible(for: info)) { tab in
                    tab.makeView(context)
                        .tabItem { Label(String(localized: tab.title), systemImage: tab.systemImage) }
                        .tag(tab.id)
                }
            }
        } else {
            ProgressView()
        }
    }
}
