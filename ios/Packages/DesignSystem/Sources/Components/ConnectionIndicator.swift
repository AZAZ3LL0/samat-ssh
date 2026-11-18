import AgentKit
import SwiftUI

/// A dot and a word for how fresh the server's data is.
public struct ConnectionIndicator: View {
    let state: ConnectionState

    public init(state: ConnectionState) {
        self.state = state
    }

    public var body: some View {
        // A stale label says "updated 5 min ago", which has to keep counting.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label {
                Text(Self.title(for: state, now: context.date))
            } icon: {
                Image(systemName: state == .connecting ? "circle.dotted" : "circle.fill")
                    .foregroundStyle(Self.color(for: state))
                    .imageScale(.small)
            }
            .font(DS.Typography.metricLabel)
            .foregroundStyle(.secondary)
        }
    }

    nonisolated static func title(for state: ConnectionState, now: Date = .now) -> String {
        switch state {
        case .connecting:
            String(localized: "Connecting…", bundle: .module)
        case .connected:
            String(localized: "Live", bundle: .module)
        case .offline:
            String(localized: "Offline", bundle: .module)
        case .stale(let since):
            String(localized: "Updated \(DSFormat.relative(since, now: now))", bundle: .module)
        }
    }

    nonisolated static func color(for state: ConnectionState) -> Color {
        switch state {
        case .connected: DS.Palette.ok
        case .connecting: DS.Palette.inactive
        case .stale: DS.Palette.warning
        case .offline: DS.Palette.critical
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: DS.Spacing.s) {
        ConnectionIndicator(state: .connected)
        ConnectionIndicator(state: .connecting)
        ConnectionIndicator(state: .stale(since: .now.addingTimeInterval(-420)))
        ConnectionIndicator(state: .offline)
    }
    .padding()
}
