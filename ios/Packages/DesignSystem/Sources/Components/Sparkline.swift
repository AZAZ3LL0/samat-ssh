import Charts
import SwiftUI

/// A small line chart without axes for list rows. `range` fixes the vertical scale,
/// for example `0...1` for ratios, so rows stay comparable; `nil` fits the values.
public struct Sparkline: View {
    let values: [Double]
    let range: ClosedRange<Double>?
    var color: Color = DS.Palette.accent

    public init(values: [Double], range: ClosedRange<Double>? = nil) {
        self.values = values
        self.range = range
    }

    public var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            LineMark(x: .value("Index", point.offset), y: .value("Value", point.element))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: range ?? Self.fit(values))
        .accessibilityHidden(true)
    }

    /// Changes the line color; the default is the accent.
    public func tint(_ color: Color) -> Self {
        var copy = self
        copy.color = color
        return copy
    }

    /// A flat series still needs a non-empty domain, or Charts draws nothing.
    nonisolated static func fit(_ values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return 0...1 }
        return low == high ? (low - 1)...(high + 1) : low...high
    }
}

#Preview {
    VStack(spacing: DS.Spacing.l) {
        Sparkline(values: [0.2, 0.35, 0.3, 0.6, 0.55, 0.8, 0.7], range: 0...1)
        Sparkline(values: [5, 5, 5, 5]).tint(DS.Palette.chartMemory)
        Sparkline(values: [])
    }
    .frame(width: 120, height: 120)
    .padding()
}
