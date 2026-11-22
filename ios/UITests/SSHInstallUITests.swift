import UIKit
import XCTest

/// S1.3 in demo mode: install the agent over SSH on the fake server and land on the new server.
@MainActor final class SSHInstallUITests: XCTestCase {
    /// Fingerprint of `FakeSSHConnector.hostKey`; UI tests cannot import AgentKit.
    private let hostKeyFingerprint = "SHA256:oBfTk/uySMp0cLuj9vZ+Y0xrRc9gkOt+b6F7gtDmwWs"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testInstallsOverSSHAfterHostKeyCheck() {
        let app = XCUIApplication()
        app.launchArguments = ["-PulseDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let add = app.buttons["Add server"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let ssh = app.buttons["addServer.ssh"]
        XCTAssertTrue(ssh.waitForExistence(timeout: 5))
        ssh.tap()

        let host = app.textFields["sshInstall.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        host.typeText("demo.local")
        let password = app.secureTextFields["sshInstall.password"]
        paste("demo", into: password, app: app)
        let connect = app.buttons["sshInstall.connect"]
        XCTAssertTrue(connect.isEnabled, "the password did not reach the secure field")
        connect.tap()

        let fingerprint = app.staticTexts["sshInstall.fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 10))
        XCTAssertEqual(fingerprint.label, hostKeyFingerprint)
        app.buttons["sshInstall.trust"].tap()

        let install = app.buttons["sshInstall.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        // LabeledContent reads as one element, "System" plus the value.
        let system = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Ubuntu 24.04.1 LTS'"))
        XCTAssertTrue(system.firstMatch.exists)
        install.tap()

        XCTAssertTrue(app.tabBars.firstMatch.buttons["Overview"].waitForExistence(timeout: 10))
    }

    /// Typed text never reaches a SecureField in the simulator; the edit menu's Paste does.
    private func paste(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        UIPasteboard.general.string = text
        field.tap()
        field.press(forDuration: 1.0)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
    }
}
