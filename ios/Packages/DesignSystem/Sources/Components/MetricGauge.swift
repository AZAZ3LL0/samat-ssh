import SwiftUI

/// A circular gauge for a `0..1` ratio, colored by `DS.Thresholds`. `nil` shows "—" on an empty ring.
public struct MetricGauge: View {
    let title: String
    let ratio: Double?
    let caption: String?

    public init(title: String, ratio: Double?, caption: String? = nil) {
        self.title = title
        self.ratio = ratio
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            Gauge(value: min(max(ratio ?? 0, 0), 1)) {
                EmptyView()
            } currentValueLabel: {
                Text(DSFormat.ratio(ratio))
                    .font(DS.Typography.metricValue)
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(DS.Thresholds.severity(of: ratio).color)
            .scaleEffect(1.4)
            .frame(width: 80, height: 80)
            Text(title)
                .font(DS.Typography.metricLabel)
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(DS.Typography.metricLabel)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([DSFormat.ratio(ratio), caption].compactMap(\.self).joined(separator: ", "))
    }
}

#Preview {
    HStack(spacing: DS.Spacing.xl) {
        MetricGauge(title: "CPU", ratio: 0.42, caption: "8 cores")
        MetricGauge(title: "RAM", ratio: 0.81, caption: "12.9 GB")
        MetricGauge(title: "Disk", ratio: 0.95, caption: nil)
        MetricGauge(title: "Swap", ratio: nil, caption: nil)
    }
    .padding()
}
