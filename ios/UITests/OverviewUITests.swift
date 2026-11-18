import XCTest

/// Demo mode end to end: server list → demo server → Overview → seed CPU and memory, updating live.
@MainActor final class OverviewUITests: XCTestCase {
    /// Gauge values of `fixtures/host_metrics/01…05.json` as `DSFormat.ratio` renders them.
    private let seedCPU: Set<String> = ["18%", "24%", "41%", "33%", "21%"]
    private let seedMemory: Set<String> = ["64%", "66%", "70%", "68%", "65%"]

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testDemoServerShowsLiveCPUAndMemoryFromSeedData() {
        let app = XCUIApplication()
        // English UI so the queries below match regardless of the simulator language.
        app.launchArguments = ["-PulseDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let demo = app.buttons["Demo server"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()
        let overview = app.tabBars.firstMatch.buttons["Overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        overview.tap()

        let cpu = app.otherElements["overview.cpu"]
        let memory = app.otherElements["overview.memory"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 10))
        XCTAssertTrue(memory.exists)
        XCTAssertEqual(cpu.label, "CPU")
        XCTAssertEqual(memory.label, "Memory")
        // Values look like "18%, 4 cores": the ratio, then the caption.
        XCTAssertTrue(cpu.value(in: seedCPU), "CPU gauge reads \(cpu.valueText)")
        XCTAssertTrue(cpu.valueText.hasSuffix("4 cores"), "CPU gauge reads \(cpu.valueText)")
        XCTAssertTrue(memory.value(in: seedMemory), "memory gauge reads \(memory.valueText)")
        XCTAssertTrue(app.staticTexts["CPU, last minute"].exists)

        // The demo agent publishes every second and the seed values differ, so the gauge moves.
        let first = cpu.valueText
        let moved = expectation(for: NSPredicate { _, _ in cpu.valueText != first }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        XCTAssertTrue(cpu.value(in: seedCPU), "CPU gauge reads \(cpu.valueText)")
    }
}

extension XCUIElement {
    fileprivate var valueText: String { value as? String ?? "" }

    /// Whether the accessibility value starts with one of `ratios`.
    fileprivate func value(in ratios: Set<String>) -> Bool {
        ratios.contains(valueText.components(separatedBy: ", ").first ?? "")
    }
}
