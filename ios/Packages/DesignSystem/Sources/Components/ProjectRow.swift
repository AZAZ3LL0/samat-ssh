import SwiftUI

/// A project in a list: name, kind, status, live CPU and memory, and a CPU sparkline.
public struct ProjectRow: View {
    let name: String
    let kind: String
    let status: ProjectStatusStyle
    let cpuRatio: Double?
    let memoryBytes: Int64?
    let sparkline: [Double]

    public init(
        name: String,
        kind: String,
        status: ProjectStatusStyle,
        cpuRatio: Double?,
        memoryBytes: Int64?,
        sparkline: [Double]
    ) {
        self.name = name
        self.kind = kind
        self.status = status
        self.cpuRatio = cpuRatio
        self.memoryBytes = memoryBytes
        self.sparkline = sparkline
    }

    public var body: some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.s) {
                    StatusBadge(status: status)
                    Text(kind)
                        .font(DS.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            Sparkline(values: sparkline, range: 0...1)
                .tint(DS.Palette.chartCPU)
                .frame(width: 56, height: 24)
            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                Text(DSFormat.ratio(cpuRatio))
                    .foregroundStyle(DS.Thresholds.severity(of: cpuRatio).color)
                Text(DSFormat.bytes(memoryBytes))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.monospacedDigit())
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    List {
        ProjectRow(
            name: "web",
            kind: "compose",
            status: .running,
            cpuRatio: 0.12,
            memoryBytes: 734_003_200,
            sparkline: [0.1, 0.14, 0.12, 0.2, 0.15, 0.12]
        )
        ProjectRow(
            name: "worker",
            kind: "pm2",
            status: .degraded,
            cpuRatio: 0.93,
            memoryBytes: 2_147_483_648,
            sparkline: [0.6, 0.8, 0.9, 0.95, 0.93]
        )
        ProjectRow(name: "backup", kind: "systemd", status: .stopped, cpuRatio: nil, memoryBytes: nil, sparkline: [])
    }
}
