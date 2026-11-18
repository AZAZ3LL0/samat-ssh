import Foundation
import Testing

@testable import DesignSystem

@Suite struct DSFormatTests {
    static let english = Locale(identifier: "en_US")

    @Test(arguments: [
        DSFormat.bytes(nil), DSFormat.bytes(-1),
        DSFormat.bps(nil), DSFormat.bps(-1), DSFormat.bps(.nan), DSFormat.bps(.infinity),
        DSFormat.ratio(nil), DSFormat.ratio(-0.01), DSFormat.ratio(.nan),
        DSFormat.duration(seconds: nil), DSFormat.duration(seconds: -1),
        DSFormat.relative(nil),
    ])
    func rendersUnknownValuesAsPlaceholder(text: String) {
        #expect(text == "—")
    }

    @Test(arguments: [
        (Int64(0), "0 bytes"), (512, "512 bytes"), (1024, "1 kB"), (8_000_000_000, "7.45 GB"),
    ])
    func formatsBytesInBinaryUnits(value: Int64, expected: String) {
        #expect(DSFormat.bytes(value, locale: Self.english) == expected)
    }

    @Test(arguments: [(0.0, "0 bytes/s"), (999.6, "1 kB/s"), (1_500_000, "1.5 MB/s")])
    func formatsThroughputPerSecond(value: Double, expected: String) {
        #expect(DSFormat.bps(value, locale: Self.english) == expected)
    }

    @Test(arguments: [(0.0, "0%"), (0.004, "0%"), (0.125, "13%"), (0.5, "50%"), (0.756, "76%"), (1.0, "100%")])
    func formatsRatioAsWholePercent(value: Double, expected: String) {
        #expect(DSFormat.ratio(value, locale: Self.english) == expected)
    }

    /// Generated inputs: every ratio in `0...1` maps to the nearest whole percent.
    @Test func ratioMatchesNearestPercentAcrossRange() throws {
        for step in 0...1000 {
            let value = Double(step) / 1000
            let text = DSFormat.ratio(value, locale: Self.english)
            let percent = try #require(Int(text.dropLast()), "ratio \(value) as \(text)")
            // Binary doubles sit a hair off exact halves, so allow either neighbor there.
            #expect(abs(Double(percent) - value * 100) <= 0.5 + 1e-9, "ratio \(value) as \(text)")
            #expect(text.hasSuffix("%"))
        }
    }

    /// Generated inputs: any known size or speed renders as text, never as the placeholder.
    @Test func knownSizesNeverRenderAsPlaceholder() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = Int64.random(in: 0...Int64.max, using: &generator)
            let speed = Double.random(in: 0...1e12, using: &generator)
            #expect(DSFormat.bytes(bytes) != DSFormat.placeholder)
            #expect(DSFormat.bps(speed) != DSFormat.placeholder)
        }
    }

    @Test(arguments: [(0, "0s"), (59, "59s"), (61, "1m 1s"), (3600, "1h"), (273_600, "3d 4h")])
    func formatsDurationWithTwoLargestUnits(seconds: Int, expected: String) {
        #expect(DSFormat.duration(seconds: seconds, locale: Self.english) == expected)
    }

    @Test func formatsRelativeTimeInThePast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DSFormat.relative(now, now: now, locale: Self.english) == "now")
        #expect(DSFormat.relative(now.addingTimeInterval(-300), now: now, locale: Self.english) == "5 min. ago")
    }

    @Test func treatsFutureDatesFromClockSkewAsNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(DSFormat.relative(now.addingTimeInterval(3), now: now, locale: Self.english) == "now")
    }

    @Test func followsTheLocale() {
        let russian = Locale(identifier: "ru_RU")
        #expect(DSFormat.bytes(8_000_000_000, locale: russian).hasSuffix("ГБ"))
        #expect(DSFormat.duration(seconds: 3600, locale: russian).hasSuffix("ч"))
        #expect(DSFormat.bps(2_000, locale: russian).hasSuffix("/с"))
    }
}
