import XCTest

/// S1.4 in demo mode: status in the list, quick switch in the server header, delete with token revocation.
@MainActor final class ServerListUITests: XCTestCase {
    /// `FakeAgentPairing.fingerprint` and `FakeAgentClient.pairingCode`; UI tests cannot import AgentKit.
    private let fingerprint = "F0sRU55fRw86KcEnEi8xyNqveEHDm5UWO5HH3sx8F_E"
    private let pairingCode = "DEMO2345"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSwitchesFromHeaderAndDeletesServer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PulseDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Add server"].waitForExistence(timeout: 10))

        // A paired server named after the demo agent's hostname.
        let link = try XCTUnwrap(URL(string: "pulse://pair?h=list.local&p=7443&fp=\(fingerprint)&c=\(pairingCode)"))
        app.open(link)
        let pair = app.buttons["addServer.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()
        XCTAssertTrue(app.tabBars.firstMatch.buttons["Overview"].waitForExistence(timeout: 10))

        let switcher = app.buttons["server.switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertTrue(switcher.label.hasPrefix("demo"))
        switcher.tap()
        app.buttons["Demo server"].tap()
        XCTAssertTrue(
            app.buttons["server.switcher"].waitForExistence(timeout: 5)
                && app.buttons["server.switcher"].label.hasPrefix("Demo server"))

        app.navigationBars.buttons["Servers"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "demo, Live")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the paired server answers and shows as live")

        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        // The confirmation dialog asks before the token is revoked.
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 10)
        let demo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Demo server")).firstMatch
        XCTAssertTrue(demo.exists)
    }
}
