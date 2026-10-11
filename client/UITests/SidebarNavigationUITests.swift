import XCTest

/// Drives the sidebar like a user does and verifies each row actually
/// switches the detail column (asserted via the window's navigation title).
final class SidebarNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTwoWindowsNavigateAndPresentShortcutsIndependently() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CS_IN_MEMORY_DB"] = "1"
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let later = app.buttons["Set Up Later"].firstMatch
        if later.waitForExistence(timeout: 3) { later.click() }

        app.typeKey("2", modifierFlags: .command)
        let first = app.windows["Watching"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let second = app.windows["Home"]
        XCTAssertTrue(second.waitForExistence(timeout: 10), "New window must have independent initial navigation")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.windows["Plan to Watch"].waitForExistence(timeout: 10))
        XCTAssertTrue(first.exists, "Navigating the second window changed the first")

        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.windows["Plan to Watch"].buttons["Done"].waitForExistence(timeout: 10))
        XCTAssertFalse(first.buttons["Done"].exists, "Shortcut sheet belongs only to its focused window")
        app.buttons["Done"].firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(first.exists)
        first.click()
        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 10), "Closing another window broke command routing")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.toolbars.buttons["Advanced"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.windows["Home"].waitForExistence(timeout: 10), "Go commands from Settings must retain their main-window target")
    }

    @MainActor
    func testLibrarySidebarRowsNavigate() throws {
        let app = XCUIApplication()
        // Isolated data, like every UI test: never the user's library.
        app.launchEnvironment["CS_IN_MEMORY_DB"] = "1"
        app.launch()
        defer { app.terminate() }
        app.activate()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20), "app window did not appear")
        // A fresh library opens with the onboarding sheet, which takes every click.
        let later = app.buttons["Set Up Later"].firstMatch
        if later.waitForExistence(timeout: 3) { later.click() }
        XCTAssertTrue(window.title.contains("Home"), "app should start on Home, got “\(window.title)”")

        func clickRow(_ label: String) {
            let row = app.staticTexts[label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "sidebar row “\(label)” not found")
            if row.isHittable {
                row.click()
            } else {
                row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            }
        }

        func expectTitle(_ title: String, timeout: TimeInterval = 10) -> Bool {
            let predicate = NSPredicate(format: "title == %@", title)
            let expectation = expectation(for: predicate, evaluatedWith: window)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }

        // The Library rows.
        for row in ["Plan to Watch", "Favorites", "Completed", "On Hold", "Dropped"] {
            clickRow(row)
            XCTAssertTrue(expectTitle(row), "clicking “\(row)” did not switch the detail column")
        }

        // The remaining destinations.
        clickRow("Downloaded")
        XCTAssertTrue(expectTitle("Downloads"))
        clickRow("History")
        XCTAssertTrue(expectTitle("History"))
        clickRow("Extensions")
        XCTAssertTrue(expectTitle("Extensions"))
        clickRow("Home")
        XCTAssertTrue(expectTitle("Home"))
        clickRow("Search")
        XCTAssertTrue(expectTitle("Search"))

        // Round-trip: out to another destination and straight back into the Library.
        clickRow("Watching")
        XCTAssertTrue(expectTitle("Watching"))
        clickRow("Home")
        XCTAssertTrue(expectTitle("Home"))
    }
}
