import Charts
import SwiftUI

/// One history bucket: the agent stores `min`, `avg` and `max` per bucket (`tech.md` 7.2).
public struct ChartPoint: Sendable, Hashable {
    public let date: Date
    public let min: Double
    public let avg: Double
    public let max: Double

    public init(date: Date, min: Double, avg: Double, max: Double) {
        self.date = date
        self.min = min
        self.avg = avg
        self.max = max
    }
}

public struct ChartSeries: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let color: Color
    public let points: [ChartPoint]

    public init(id: String, title: String, color: Color, points: [ChartPoint]) {
        self.id = id
        self.title = title
        self.color = color
        self.points = points
    }
}

/// History windows offered on charts.
public enum TimeRange: String, Sendable, CaseIterable, Identifiable {
    case hour, day, week, month

    public var id: Self { self }

    public var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .hour: String(localized: "1 h", bundle: .module, comment: "Chart range: one hour")
        case .day: String(localized: "24 h", bundle: .module, comment: "Chart range: one day")
        case .week: String(localized: "7 d", bundle: .module, comment: "Chart range: one week")
        case .month: String(localized: "30 d", bundle: .module, comment: "Chart range: thirty days")
        }
    }
}

/// The API unit of a chart's values; axis labels go through `DSFormat`.
public enum ChartUnit: Sendable {
    case ratio, bytes, bps

    public func format(_ value: Double) -> String {
        switch self {
        case .ratio: DSFormat.ratio(value)
        case .bytes: DSFormat.bytes(value.isFinite ? Int64(value) : nil)
        case .bps: DSFormat.bps(value)
        }
    }
}

/// History of one or more series: an `avg` line over a `min`–`max` band.
public struct TimeSeriesChart: View {
    let series: [ChartSeries]
    let range: TimeRange
    let unit: ChartUnit

    public init(series: [ChartSeries], range: TimeRange, unit: ChartUnit) {
        self.series = series
        self.range = range
        self.unit = unit
    }

    public var body: some View {
        Chart {
            ForEach(series) { line in
                ForEach(line.points, id: \.date) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Min", point.min),
                        yEnd: .value("Max", point.max),
                        series: .value("Series", line.id)
                    )
                    .foregroundStyle(by: .value("Series", line.title))
                    .opacity(0.2)
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Average", point.avg),
                        series: .value("Series", line.id)
                    )
                    .foregroundStyle(by: .value("Series", line.title))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: Self.domain(of: series, range: range))
        .chartYScale(domain: unit == .ratio ? 0...1 : Self.valueDomain(of: series))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(unit.format(number))
                    }
                }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartForegroundStyleScale(domain: series.map(\.title), range: series.map(\.color))
    }

    /// The window ends at the newest point, so a chart of cached history does not look empty.
    nonisolated static func domain(of series: [ChartSeries], range: TimeRange, now: Date = .now) -> ClosedRange<Date> {
        let end = series.flatMap(\.points).map(\.date).max() ?? now
        return end.addingTimeInterval(-range.seconds)...end
    }

    /// From zero: bytes and speeds read wrong when the axis starts at an arbitrary value.
    nonisolated static func valueDomain(of series: [ChartSeries]) -> ClosedRange<Double> {
        let top = series.flatMap(\.points).map(\.max).filter(\.isFinite).max() ?? 0
        return 0...Swift.max(top, 1)
    }
}

#Preview {
    let now = Date.now
    let points: (Double) -> [ChartPoint] = { base in
        (0..<60).map { minute in
            let wave = base + 0.15 * sin(Double(minute) / 6)
            let date = now.addingTimeInterval(Double(minute - 60) * 60)
            return ChartPoint(date: date, min: wave - 0.05, avg: wave, max: wave + 0.08)
        }
    }
    TimeSeriesChart(
        series: [
            ChartSeries(id: "cpu", title: "CPU", color: DS.Palette.chartCPU, points: points(0.4)),
            ChartSeries(id: "memory", title: "RAM", color: DS.Palette.chartMemory, points: points(0.7)),
        ],
        range: .hour,
        unit: .ratio
    )
    .frame(height: 220)
    .padding()
}
