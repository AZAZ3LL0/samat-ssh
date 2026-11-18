import Foundation
import SwiftUI
import Testing

@testable import DesignSystem

@Suite struct ComponentLogicTests {
    @Test func everyProjectStatusHasItsOwnTitle() {
        let titles = ProjectStatusStyle.allCases.map(\.title)
        #expect(!titles.contains(""))
        #expect(Set(titles).count == titles.count)
    }

    @Test func highlightsEveryMatchIgnoringCase() {
        let text = LogLineView.highlighted("refused: Connection REFUSED", matching: "refused")
        let marked = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(marked == ["refused", "REFUSED"])
    }

    @Test(arguments: [nil, ""])
    func leavesLogLineUnmarkedWithoutQuery(query: String?) {
        let text = LogLineView.highlighted("refused", matching: query)
        #expect(text.runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test func sparklineScaleCoversValuesAndNeverCollapses() {
        #expect(Sparkline.fit([]) == 0...1)
        #expect(Sparkline.fit([3, 1, 2]) == 1...3)
        #expect(Sparkline.fit([5, 5]) == 4...6)
        #expect(Sparkline.fit([.nan, 2, 4]) == 2...4)
    }
}
