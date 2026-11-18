import Foundation
import SwiftUI
import Testing

@testable import DesignSystem

@Suite struct ThresholdsTests {
    @Test(arguments: [
        (0.0, DS.Severity.ok), (0.7499, .ok), (0.75, .warning), (0.8999, .warning), (0.9, .critical), (1.0, .critical),
        (1.7, .critical),
    ])
    func classifiesRatioAtBoundaries(ratio: Double, expected: DS.Severity) {
        #expect(DS.Thresholds.severity(of: ratio) == expected)
    }

    @Test(arguments: [nil, Double.nan, .infinity])
    func treatsUnknownRatioAsUnknown(ratio: Double?) {
        #expect(DS.Thresholds.severity(of: ratio) == .unknown)
    }

    /// Generated inputs: severity never drops as the ratio grows.
    @Test func severityIsMonotonicInRatio() {
        let rank: [DS.Severity: Int] = [.ok: 0, .warning: 1, .critical: 2]
        var previous = 0
        for step in 0...2000 {
            let current = rank[DS.Thresholds.severity(of: Double(step) / 1000)] ?? -1
            #expect(current >= previous, "ratio \(Double(step) / 1000)")
            previous = current
        }
    }
}

#if canImport(UIKit)
    import UIKit

    @Suite struct PaletteTests {
        @Test(arguments: [
            "ok", "warning", "critical", "inactive", "accent",
            "chartCPU", "chartMemory", "chartDisk", "chartNetRx", "chartNetTx",
        ])
        func colorExistsWithLightAndDarkVariants(name: String) throws {
            let color = try #require(UIColor(named: name, in: .module, compatibleWith: nil))
            let light = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            let dark = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            #expect(light != dark)
        }
    }
#endif
