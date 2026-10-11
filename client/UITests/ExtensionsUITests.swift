import XCTest

/// Extension flows that need no network (plan T9.2). The app runs with an
/// isolated in-memory library and a temporary engine data root, so these
/// tests never touch the user's saved extensions or library.
final class ExtensionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CS_IN_MEMORY_DB"] = "1"
        environment.forEach { app.launchEnvironment[$0.key] = $0.value }
        app.launch()
        // Another app may hold focus on a shared desktop; clicks need the app in front.
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "app window did not appear")
        let later = app.buttons["Set Up Later"]
        if later.waitForExistence(timeout: 3) { later.click() }
        return app
    }

    @MainActor
    private func openExtensions(_ app: XCUIApplication) {
        app.activate()
        let row = app.staticTexts["Extensions"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Extensions sidebar row not found")
        row.click()
        // "Add Repository" enables once the engine is ready.
        let add = app.buttons["Add Repository"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: add)
        wait(for: [enabled], timeout: 60)
    }

    /// SwiftUI `Text` exposes its string as the element's value on macOS.
    @MainActor
    private func text(_ app: XCUIApplication, beginningWith prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func waitForText(_ app: XCUIApplication, beginningWith prefix: String, timeout: TimeInterval = 30) -> XCUIElement {
        let element = text(app, beginningWith: prefix)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "text “\(prefix)…” did not appear")
        return element
    }

    /// Mouse-only: synthesized typing is unreliable on shared desktops, and URL
    /// validation is covered by the engine and store tests.
    @MainActor
    func testExtensionsScreenOffersSectionsAndTheAddRepositorySheet() throws {
        let app = launch()
        openExtensions(app)
        XCTAssertTrue(app.radioButtons["Installed"].exists || app.buttons["Installed"].exists, "section picker missing")
        let repositories = app.radioButtons["Repositories"].exists ? app.radioButtons["Repositories"] : app.buttons["Repositories"]
        repositories.click()

        app.buttons["Add Repository"].firstMatch.click()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'https://'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "repository URL field missing")
        _ = waitForText(app, beginningWith: "Enter a repository URL or shortcode")
        app.buttons["Cancel"].firstMatch.click()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: field)
        wait(for: [closed], timeout: 10)
    }

    @MainActor
    func testSafeModeCanBeEnteredFromSettingsAndLeftFromExtensions() throws {
        let app = launch()
        openExtensions(app)

        app.typeKey(",", modifierFlags: .command)
        let advanced = app.toolbars.buttons["Advanced"].firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), "Settings → Advanced not found")
        advanced.click()
        XCTAssertTrue(app.buttons["Export Diagnostics…"].waitForExistence(timeout: 5), "Export Diagnostics missing")
        app.buttons["Restart in Safe Mode"].click()
        app.typeKey("w", modifierFlags: .command)

        openExtensions(app)
        _ = waitForText(app, beginningWith: "Safe mode is on")
        let restart = app.buttons["Restart Normally"].firstMatch
        // Regression: in safe mode the Extensions layout once demanded more height than
        // the window had, pushing the header, banners and sidebar off the top.
        XCTAssertTrue(restart.isHittable, "safe-mode banner action is off-screen (frame \(restart.frame))")
        XCTAssertTrue(app.buttons["Add Repository"].firstMatch.isHittable, "Extensions header is off-screen")
        XCTAssertTrue(app.staticTexts["Home"].firstMatch.isHittable, "sidebar is shifted off-screen")
        restart.click()
        openExtensions(app)
        let banner = text(app, beginningWith: "Safe mode is on")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: banner)
        wait(for: [gone], timeout: 60)
    }

    /// Real engine and sandboxed worker, no network: the Debug-only hook imports
    /// the d8-built fixture through developer mode (it starts disabled).
    @MainActor
    func testInstalledExtensionCanBeEnabledDisabledAndUninstalled() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../engine/src/test/resources/extensions/fixture.cs3").standardized
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), "fixture missing at \(fixture.path)")
        let app = launch(environment: ["CS_UITEST_DEVELOPER_EXTENSION": fixture.path])
        openExtensions(app)
        (app.radioButtons["Installed"].exists ? app.radioButtons["Installed"] : app.buttons["Installed"]).click()

        // SwiftUI switch-style toggles are checkboxes to XCTest on macOS.
        let toggle = app.checkBoxes["Enable fixture"].firstMatch
        _ = toggle.waitForExistence(timeout: 60)
        XCTAssertTrue(toggle.exists, "imported extension not listed")
        XCTAssertTrue(app.descendants(matching: .any)["Developer extension"].firstMatch.exists, "tier badge missing")
        let disabled = text(app, beginningWith: "Disabled")
        XCTAssertTrue(disabled.waitForExistence(timeout: 10), "a new import starts disabled")
        XCTAssertFalse(text(app, beginningWith: "Its repository was removed").exists, "developer imports never had a repository")

        toggle.click()
        let running = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: disabled)
        wait(for: [running], timeout: 60) // starts a sandboxed worker for the extension

        toggle.click()
        XCTAssertTrue(text(app, beginningWith: "Disabled").waitForExistence(timeout: 30), "disable did not apply")

        app.menuButtons["More actions for fixture"].firstMatch.click()
        app.menuItems["Uninstall…"].firstMatch.click()
        // Scope to the confirmation sheet: the Touch Bar mirrors the same button.
        let confirm = app.sheets.buttons["Uninstall Extension"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()
        XCTAssertTrue(text(app, beginningWith: "No Extensions Installed").waitForExistence(timeout: 30), "uninstall did not apply")
    }

    /// Automated accessibility audit of the Extensions screen with an extension
    /// installed (complements the manual VoiceOver checklist, plan T7.8).
    @MainActor
    func testExtensionsScreenPassesTheAccessibilityAudit() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../engine/src/test/resources/extensions/fixture.cs3").standardized
        let app = launch(environment: ["CS_UITEST_DEVELOPER_EXTENSION": fixture.path])
        openExtensions(app)
        (app.radioButtons["Installed"].exists ? app.radioButtons["Installed"] : app.buttons["Installed"]).click()
        XCTAssertTrue(app.checkBoxes["Enable fixture"].firstMatch.waitForExistence(timeout: 60))
        let sidebarRows: Set<String> = ["Home", "Search", "Watching", "Plan to Watch", "Favorites", "Completed",
                                        "On Hold", "Dropped", "Downloaded", "History", "Extensions"]
        try app.performAccessibilityAudit { issue in
            guard let element = issue.element else { return true }
            let text = (element.value as? String) ?? element.label
            switch element.elementType {
            // SwiftUI-generated containers (not views we author) and the Touch Bar.
            case .group, .outline, .touchBar: return true
            // Borderless SwiftUI Menu: clickable, opened by VoiceOver's show-menu command.
            case .menuButton where issue.compactDescription.contains("Action"): return true
            // App-wide sidebar styling, tracked outside the extension screens.
            case .staticText where sidebarRows.contains(text) && issue.compactDescription.contains("Contrast"): return true
            default:
                print("AXAUDIT \(issue.compactDescription): \(element.elementType.rawValue) “\(text)”")
                return false // anything else fails the test
            }
        }
    }
}
