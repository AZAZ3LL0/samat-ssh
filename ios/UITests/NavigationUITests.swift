import XCTest

/// Demo mode end to end: server list → demo server → tabs from the registry → seed data.
@MainActor final class NavigationUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        // English UI so the queries below match regardless of the simulator language.
        app.launchArguments = ["-PulseDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    func testDemoServerShowsTabsFromRegistryAndSeedData() {
        let app = launchDemo()
        let demo = app.buttons["Demo server"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Overview"].waitForExistence(timeout: 10))
        XCTAssertTrue(tabBar.buttons["Info"].exists)
        // The demo agent reports host_metrics only, so these stay hidden.
        XCTAssertFalse(tabBar.buttons["Projects"].exists)
        XCTAssertFalse(tabBar.buttons["Logs"].exists)

        tabBar.buttons["Info"].tap()
        // LabeledContent reads as one element, "Hostname, demo"; values come from fixtures/agent_info/demo.json.
        XCTAssertTrue(app.staticTexts["Hostname, demo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Agent version, 0.1.0"].exists)
        XCTAssertTrue(app.staticTexts["host_metrics"].exists)
    }

    func testDebugMenuOpensDesignSystemShowcase() {
        let app = launchDemo()
        let debug = app.buttons["Debug"]
        XCTAssertTrue(debug.waitForExistence(timeout: 10))
        debug.tap()
        app.buttons["Design system"].tap()
        XCTAssertTrue(app.navigationBars["Design system"].waitForExistence(timeout: 5))
        // iOS 17 and 18 uppercase List section headers, iOS 26 does not.
        let palette = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Palette")).firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
    }
}
