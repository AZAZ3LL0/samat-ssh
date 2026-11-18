import AgentKit
import SwiftUI

/// Every token and component on one screen, reachable from the app's debug menu.
/// Sample values are fixed so the screen reads the same on every run.
public struct DesignSystemShowcase: View {
    @State private var range = TimeRange.hour
    @State private var confirming = false

    public init() {}

    public var body: some View {
        List {
            Section("Palette") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: DS.Spacing.s) {
                    ForEach(Self.swatches, id: \.name) { swatch in
                        VStack(spacing: DS.Spacing.xs) {
                            RoundedRectangle(cornerRadius: DS.Radius.s).fill(swatch.color).frame(height: 32)
                            Text(swatch.name).font(DS.Typography.metricLabel)
                        }
                    }
                }
            }
            Section("Typography") {
                Text(DSFormat.ratio(0.42)).font(DS.Typography.metricValue)
                Text("metricLabel").font(DS.Typography.metricLabel)
                Text("2026-11-18 10:00:00 log line").font(DS.Typography.log)
            }
            Section("DSFormat") {
                LabeledContent("bytes", value: DSFormat.bytes(13_958_643_712))
                LabeledContent("bps", value: DSFormat.bps(1_250_000))
                LabeledContent("ratio", value: DSFormat.ratio(0.756))
                LabeledContent("duration", value: DSFormat.duration(seconds: 273_600))
                LabeledContent("relative", value: DSFormat.relative(.now.addingTimeInterval(-300)))
                LabeledContent("unknown", value: DSFormat.bytes(nil))
            }
            Section("MetricGauge") {
                HStack {
                    MetricGauge(title: "CPU", ratio: 0.42, caption: "8 cores")
                    MetricGauge(title: "RAM", ratio: 0.81, caption: DSFormat.bytes(13_958_643_712))
                    MetricGauge(title: "Disk", ratio: 0.95)
                    MetricGauge(title: "Swap", ratio: nil)
                }
            }
            Section("Sparkline") {
                Sparkline(values: Self.wave(count: 30, base: 0.5), range: 0...1).frame(height: 40)
            }
            Section("TimeSeriesChart") {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TimeSeriesChart(series: Self.history(range: range), range: range, unit: .ratio)
                    .frame(height: 200)
            }
            Section("StatusBadge") {
                ForEach(ProjectStatusStyle.allCases, id: \.self) { StatusBadge(status: $0) }
            }
            Section("ProjectRow") {
                ProjectRow(
                    name: "web",
                    kind: "compose",
                    status: .running,
                    cpuRatio: 0.12,
                    memoryBytes: 734_003_200,
                    sparkline: Self.wave(count: 20, base: 0.15)
                )
                ProjectRow(
                    name: "backup", kind: "systemd", status: .stopped, cpuRatio: nil, memoryBytes: nil, sparkline: [])
            }
            Section("LogLineView") {
                ForEach(Array(LogLevelStyle.allCases.enumerated()), id: \.offset) { index, level in
                    LogLineView(
                        ts: Self.reference.addingTimeInterval(Double(index)),
                        level: level,
                        stream: index.isMultiple(of: 3) ? "stderr" : "stdout",
                        message: "worker \(index): connection refused",
                        highlight: "refused"
                    )
                }
            }
            Section("ConnectionIndicator") {
                ConnectionIndicator(state: .connected)
                ConnectionIndicator(state: .connecting)
                ConnectionIndicator(state: .stale(since: .now.addingTimeInterval(-420)))
                ConnectionIndicator(state: .offline)
            }
            Section("ErrorBanner") {
                ErrorBanner(error: .unreachable, retry: {})
                ErrorBanner(error: .server(.upstreamUnavailable, requestId: "req-42"))
            }
            Section("ConfirmActionSheet") {
                Button("Restart web") { confirming = true }
            }
            Section("EmptyState") {
                EmptyState(
                    title: "No servers",
                    message: "Add a server to see its load.",
                    systemImage: "server.rack",
                    action: (title: "Add server", run: {})
                )
            }
        }
        .navigationTitle("Design system")
        .sheet(isPresented: $confirming) {
            // The showcase must not ask for Face ID; the real prompt is covered by ConfirmActionModel tests.
            ConfirmActionSheet(
                title: "Restart web",
                message: "The compose project web restarts. Requests fail for a few seconds.",
                destructive: true,
                requiresBiometrics: false,
                onConfirm: { try? await Task.sleep(for: .seconds(1)) }
            )
        }
    }

    private static let reference = Date(timeIntervalSince1970: 1_800_000_000)

    private static let swatches: [(name: String, color: Color)] = [
        ("ok", DS.Palette.ok), ("warning", DS.Palette.warning), ("critical", DS.Palette.critical),
        ("inactive", DS.Palette.inactive), ("accent", DS.Palette.accent), ("chartCPU", DS.Palette.chartCPU),
        ("chartMemory", DS.Palette.chartMemory), ("chartDisk", DS.Palette.chartDisk),
        ("chartNetRx", DS.Palette.chartNetRx), ("chartNetTx", DS.Palette.chartNetTx),
    ]

    private static func wave(count: Int, base: Double) -> [Double] {
        (0..<count).map { base + 0.2 * sin(Double($0) / 3) }
    }

    private static func history(range: TimeRange) -> [ChartSeries] {
        let step = range.seconds / 60
        let points: (Double) -> [ChartPoint] = { base in
            wave(count: 60, base: base).enumerated().map { index, value in
                ChartPoint(
                    date: reference.addingTimeInterval(Double(index - 59) * step),
                    min: value - 0.05,
                    avg: value,
                    max: value + 0.08
                )
            }
        }
        return [
            ChartSeries(id: "cpu", title: "CPU", color: DS.Palette.chartCPU, points: points(0.4)),
            ChartSeries(id: "memory", title: "RAM", color: DS.Palette.chartMemory, points: points(0.65)),
        ]
    }
}

#Preview {
    NavigationStack { DesignSystemShowcase() }
}
