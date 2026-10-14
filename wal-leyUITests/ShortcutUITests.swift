import XCTest

final class ShortcutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandOShowsOpenPanel() throws {
        let (app, _) = try XCUIApplication.launched()
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.waitForFilePanel(), "⌘O didn't show the open panel")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// ⌘O must keep working wherever focus is: the data grid, and the console's code editor.
    @MainActor
    func testCommandOWithDatabaseOpen() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase:
            "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a');")

        app.tables.firstMatch.click()
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.waitForFilePanel(), "⌘O didn't show the open panel from the grid")
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.textViews.firstMatch.click()
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.waitForFilePanel(), "⌘O didn't show the open panel from the console")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testCommandNShowsNewDatabasePanel() throws {
        let (app, _) = try XCUIApplication.launched()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.waitForFilePanel(), "⌘N didn't show the new database panel")
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        // The panel may hide the extension.
        XCTAssertTrue((panel.textFields.firstMatch.value as? String)?.hasPrefix("Untitled") == true)
        XCTAssertTrue(panel.buttons["Create"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testShiftCommandNOpensNewTableEditor() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: "CREATE TABLE t (id INTEGER PRIMARY KEY);")
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.tableNameField.waitForExistence(timeout: 5), "⇧⌘N didn't open the structure editor")
        XCTAssertTrue(app.buttons["Create Table"].exists)
        XCTAssertEqual(app.columnNameFields.count, 1, "a new table starts with its id column")
    }

    /// Holding ⌘ alone shows a badge on every shortcut button; letting go hides them.
    @MainActor
    func testHoldingCommandShowsShortcutHints() throws {
        let (app, _) = try XCUIApplication.launched()
        XCTAssertEqual(app.shortcutHints.count, 0)
        var shown: [String] = []
        XCUIElement.perform(withKeyModifiers: .command) {
            sleep(1)
            shown = app.shortcutHintTexts
        }
        XCTAssertTrue(shown.contains("⌘N"), "hints shown: \(shown)")
        XCTAssertTrue(shown.contains("⌘O"), "hints shown: \(shown)")
        XCTAssertTrue(shown.contains("⇧⌘W"), "hints shown: \(shown)")
        XCTAssertTrue(app.shortcutHints.firstMatch.waitForNonExistence(timeout: 2), "hints stayed after releasing ⌘")
    }

    /// XCUITest can't read SwiftUI tooltips, so this hovers each toolbar button and keeps a screenshot in the
    /// test report. The tooltip text itself is covered by `ShortcutTests`.
    @MainActor
    func testToolbarTooltipScreenshots() throws {
        let (app, _) = try XCUIApplication.launched()
        let toolbar = app.toolbars.firstMatch
        for name in ["New Database…", "Open…", "Close Database"] {
            let button = toolbar.buttons[name]
            XCTAssertTrue(button.exists, "missing toolbar button \(name)")
            button.hover()
            sleep(2)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "Tooltip: \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
