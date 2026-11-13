import XCTest

/// Settings ▸ General ▸ Delete CloudStream…: the three steps and their
/// guards. Runs isolated (CS_IN_MEMORY_DB); it never presses the final
/// Delete button, and an isolated launch refuses to delete anyway.
final class DeleteCloudStreamUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testDeleteFlowRequiresBackupDecisionAndTypedConfirmation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CS_IN_MEMORY_DB"] = "1"
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let later = app.buttons["Set Up Later"].firstMatch
        if later.waitForExistence(timeout: 3) { later.click() }

        app.typeKey(",", modifierFlags: .command)
        let open = app.buttons["Delete CloudStream Settings Button"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()

        // 1. Review
        XCTAssertTrue(app.staticTexts["Step 1 of 3 — What will be deleted"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Extensions and engine data"].firstMatch.exists)
        attach(app, "Delete — review")
        app.buttons["Continue"].firstMatch.click()

        // 2. Backup: Continue waits for a backup or an explicit opt-out.
        XCTAssertTrue(app.staticTexts["Step 2 of 3 — Back up your library"].firstMatch.waitForExistence(timeout: 5))
        let next = app.buttons["Continue"].firstMatch
        XCTAssertFalse(next.isEnabled, "Continue needs a backup or the opt-out")
        XCTAssertTrue(app.buttons["Back Up…"].firstMatch.exists)
        attach(app, "Delete — backup")
        app.checkBoxes.firstMatch.click()
        XCTAssertTrue(next.isEnabled)
        next.click()

        // 3. Confirm: the destructive button waits for the typed word.
        XCTAssertTrue(app.staticTexts["Step 3 of 3 — Confirm"].firstMatch.waitForExistence(timeout: 5))
        let delete = app.buttons["Delete CloudStream Button"].firstMatch
        XCTAssertFalse(delete.isEnabled)
        let field = app.textFields["Delete Confirmation Field"].firstMatch
        field.click()
        field.typeText("delete")
        XCTAssertFalse(delete.isEnabled, "The word is case-sensitive")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("DELETE")
        XCTAssertTrue(delete.isEnabled)
        attach(app, "Delete — confirm")

        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5), "Cancel closes the sheet and deletes nothing")
        XCTAssertTrue(open.exists)
    }
}
