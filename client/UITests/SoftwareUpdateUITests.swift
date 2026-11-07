import XCTest

/// The update row above the profile button and Settings ▸ Software Update,
/// driven against the debug update fixture (version 99.0.0; nothing is
/// downloaded or installed).
final class SoftwareUpdateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app: XCUIApplication
        if let bundleID = ProcessInfo.processInfo.environment["CS_SIDEBAR_APP_BUNDLE_ID"] {
            app = XCUIApplication(bundleIdentifier: bundleID)
        } else {
            app = XCUIApplication()
        }
        app.launchEnvironment["CS_IN_MEMORY_DB"] = "1"
        app.launchEnvironment["CS_UPDATE_FIXTURE"] = "1"
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let later = app.buttons["Set Up Later"].firstMatch
        if later.waitForExistence(timeout: 3) { later.click() }
        return app
    }

    @MainActor
    func testUpdateRowSitsAboveTheProfileAndDownloadsToRestart() throws {
        let app = launch()
        let row = app.descendants(matching: .any).matching(identifier: "Sidebar Update").firstMatch
        let profile = app.descendants(matching: .any).matching(identifier: "Sidebar Profile").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "an available update shows in the sidebar")
        XCTAssertTrue(profile.exists)
        XCTAssertLessThan(row.frame.maxY, profile.frame.minY + 1, "the update row sits directly above the profile button")
        XCTAssertLessThan(profile.frame.minY - row.frame.maxY, 24, "…with no other row between them")
        XCTAssertEqual(row.frame.midX, profile.frame.midX, accuracy: 12, "both use the sidebar's width")

        let snapshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        snapshot.name = "Sidebar — update available"
        snapshot.lifetime = .keepAlways
        add(snapshot)

        let download = app.buttons["Sidebar Update Download"].firstMatch
        XCTAssertTrue(download.exists)
        download.click()
        XCTAssertTrue(app.staticTexts["Downloading Update"].firstMatch.waitForExistence(timeout: 5))
        let downloading = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        downloading.name = "Sidebar — downloading"
        downloading.lifetime = .keepAlways
        add(downloading)

        let restart = app.buttons["Sidebar Update Restart"].firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: 15), "a verified download offers Restart")
        let ready = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        ready.name = "Sidebar — ready to restart"
        ready.lifetime = .keepAlways
        add(ready)

        // Settings shows the same state, and the menu command exists.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Restart to Update"].firstMatch.waitForExistence(timeout: 10))
        let settings = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        settings.name = "Settings — Software Update"
        settings.lifetime = .keepAlways
        add(settings)
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists)
    }

    @MainActor
    func testSkippingHidesTheRowAndSettingsStillOffersTheUpdate() throws {
        let app = launch()
        let row = app.descendants(matching: .any).matching(identifier: "Sidebar Update").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        let skip = app.menuItems["Skip This Version"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "a skipped version leaves the sidebar")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Settings Update Download"].firstMatch.waitForExistence(timeout: 10),
                      "Settings still offers the skipped version")
    }
}
