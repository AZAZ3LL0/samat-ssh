import XCTest

/// S1.1 in demo mode: add a server by address, check the fingerprint, pair with the code.
@MainActor final class AddServerUITests: XCTestCase {
    /// `FakeAgentPairing.fingerprint` and `FakeAgentClient.pairingCode`; UI tests cannot import AgentKit.
    private let fingerprint = "F0sRU55fRw86KcEnEi8xyNqveEHDm5UWO5HH3sx8F_E"
    private let pairingCode = "DEMO2345"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testAddsServerAfterFingerprintCheckAndCode() {
        let app = XCUIApplication()
        app.launchArguments = ["-PulseDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let add = app.buttons["Add server"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        let host = app.textFields["addServer.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        host.typeText("demo.local")
        app.buttons["addServer.connect"].tap()

        let shown = app.staticTexts["addServer.fingerprint"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10))
        XCTAssertEqual(shown.label, fingerprint)
        app.buttons["Fingerprints match"].tap()

        let code = app.textFields["addServer.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("WRONG234")
        app.buttons["addServer.pair"].tap()
        XCTAssertTrue(
            app.staticTexts["The code is wrong, expired or already used. Run pulse-agent pair again."]
                .waitForExistence(timeout: 5))

        // The wrong code stays in the field; a double tap selects it so typing replaces it.
        code.doubleTap()
        code.typeText(pairingCode)
        app.buttons["addServer.pair"].tap()

        // The sheet closes and the new server, named after the agent's hostname, opens.
        XCTAssertTrue(app.tabBars.firstMatch.buttons["Overview"].waitForExistence(timeout: 10))
    }
}
