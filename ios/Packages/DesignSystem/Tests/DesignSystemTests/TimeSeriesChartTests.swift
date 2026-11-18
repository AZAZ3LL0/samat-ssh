import Foundation
import Testing

@testable import DesignSystem

@Suite struct TimeSeriesChartTests {
    @Test(arguments: zip(TimeRange.allCases, [3600.0, 86_400, 604_800, 2_592_000]))
    func rangesCoverOneHourToThirtyDays(range: TimeRange, seconds: TimeInterval) {
        #expect(range.seconds == seconds)
    }

    @Test func windowEndsAtNewestPoint() {
        let newest = Date(timeIntervalSince1970: 1_800_000_000)
        let series = [
            ChartSeries(id: "a", title: "A", color: .clear, points: [Self.point(newest.addingTimeInterval(-60))]),
            ChartSeries(id: "b", title: "B", color: .clear, points: [Self.point(newest)]),
        ]
        let domain = TimeSeriesChart.domain(of: series, range: .day, now: .distantFuture)
        #expect(domain == newest.addingTimeInterval(-86_400)...newest)
    }

    @Test func emptyHistoryEndsNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TimeSeriesChart.domain(of: [], range: .hour, now: now) == now.addingTimeInterval(-3600)...now)
    }

    @Test func valueAxisStartsAtZero() {
        let series = [ChartSeries(id: "a", title: "A", color: .clear, points: [Self.point(.now, max: 5e9)])]
        #expect(TimeSeriesChart.valueDomain(of: series) == 0...5e9)
        #expect(TimeSeriesChart.valueDomain(of: []) == 0...1)
    }

    @Test func axisLabelsUseTheUnitFormat() {
        #expect(ChartUnit.ratio.format(0.5) == DSFormat.ratio(0.5))
        #expect(ChartUnit.bytes.format(1024) == DSFormat.bytes(1024))
        #expect(ChartUnit.bps.format(1e6) == DSFormat.bps(1e6))
    }

    private static func point(_ date: Date, max: Double = 1) -> ChartPoint {
        ChartPoint(date: date, min: 0, avg: max / 2, max: max)
    }
}
