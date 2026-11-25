import AgentKit
import DesignSystem
import SwiftUI

/// A server in the list: name, online or offline, and the CPU trend since the list opened.
public struct ServerRow: View {
    let name: String
    let isDemo: Bool
    let status: ServerStatusModel.Status

    public init(name: String, isDemo: Bool, status: ServerStatusModel.Status) {
        self.name = name
        self.isDemo = isDemo
        self.status = status
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label(name, systemImage: isDemo ? "sparkles" : "server.rack")
                ConnectionIndicator(state: status.connection)
                    .font(DS.Typography.metricLabel)
            }
            Spacer(minLength: DS.Spacing.s)
            if !status.cpu.isEmpty {
                Sparkline(values: status.cpu, range: 0...1)
                    .tint(DS.Palette.chartCPU)
                    .frame(width: 64, height: 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("serverRow.\(name)")
    }
}

#Preview {
    List {
        ServerRow(name: "web", isDemo: false, status: .init(connection: .connected, cpu: [0.1, 0.3, 0.2, 0.6, 0.4]))
        ServerRow(name: "db", isDemo: false, status: .init(connection: .offline, cpu: [0.2, 0.25]))
        ServerRow(name: "Demo server", isDemo: true, status: .init())
    }
}
