import AgentKit
import DesignSystem
import SwiftUI

/// CPU and memory of the server in real time.
public struct OverviewView: View {
    @State private var model: OverviewModel

    public init(context: ServerContext) {
        _model = State(initialValue: OverviewModel(context: context))
    }

    public var body: some View {
        content
            .task { await model.start() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            VStack {
                ErrorBanner(error: error) { model.retry() }
                Spacer()
            }
            .padding(DS.Spacing.l)
        case .loaded(let snapshot):
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    if let error = model.streamError {
                        ErrorBanner(error: error) { model.retry() }
                    }
                    ConnectionIndicator(state: model.connection)
                    gauges(snapshot)
                    trend(
                        String(localized: "CPU, last minute", bundle: .module),
                        values: model.cpuHistory,
                        color: DS.Palette.chartCPU
                    )
                    trend(
                        String(localized: "Memory, last minute", bundle: .module),
                        values: model.memoryHistory,
                        color: DS.Palette.chartMemory
                    )
                }
                .padding(DS.Spacing.l)
            }
        }
    }

    private func gauges(_ snapshot: OverviewSnapshot) -> some View {
        HStack(spacing: DS.Spacing.xl) {
            MetricGauge(
                title: String(localized: "CPU", bundle: .module),
                ratio: snapshot.cpuRatio,
                caption: String(localized: "\(snapshot.cores) cores", bundle: .module)
            )
            .accessibilityIdentifier("overview.cpu")
            let used = DSFormat.bytes(snapshot.memoryUsedBytes)
            let total = DSFormat.bytes(snapshot.memoryTotalBytes)
            MetricGauge(
                title: String(localized: "Memory", bundle: .module),
                ratio: snapshot.memoryRatio,
                caption: String(localized: "\(used) of \(total)", bundle: .module)
            )
            .accessibilityIdentifier("overview.memory")
        }
        .frame(maxWidth: .infinity)
    }

    private func trend(_ title: String, values: [Double], color: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(title)
                .font(DS.Typography.metricLabel)
                .foregroundStyle(.secondary)
            // Ratios share a fixed 0...1 scale, so a flat line means steady, not zoomed-in noise.
            Sparkline(values: values, range: 0...1)
                .tint(color)
                .frame(height: 56)
        }
    }
}

#Preview("Live") {
    OverviewView(context: ServerContext(serverId: UUID(), client: FakeAgentClient()))
}

#Preview("Stream drops") {
    OverviewView(context: ServerContext(serverId: UUID(), client: FakeAgentClient(mode: .dropWebSocket(after: 3))))
}

#Preview("Unreachable") {
    OverviewView(context: ServerContext(serverId: UUID(), client: FakeAgentClient(mode: .failing(.unreachable))))
}
