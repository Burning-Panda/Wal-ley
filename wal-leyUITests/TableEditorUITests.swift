import XCTest

final class TableEditorUITests: XCTestCase {
    private static let schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('a');"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateTableWithColumns() throws {
        let (app, path) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.tableNameField.waitForExistence(timeout: 5))
        app.tableNameField.click()
        app.typeText("people")

        app.addColumnRow.click()
        XCTAssertTrue(app.columnNameFields.element(boundBy: 1).waitForExistence(timeout: 2), "clicking the hint row didn't add a column")
        app.columnNameFields.element(boundBy: 1).click()
        app.typeText("email")

        app.buttons["Create Table"].click()
        XCTAssertTrue(app.tableNameField.waitForNonExistence(timeout: 5), "editor stayed open after Create Table")
        XCTAssertTrue(app.sidebarRow("people").waitForExistence(timeout: 5))
        XCTAssertEqual(try TestDatabase.columns(path!, "people"), ["id", "email"])
    }

    @MainActor
    func testClickingHintRowAddsOneColumn() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        XCTAssertEqual(app.columnNameFields.count, 2)
        app.addColumnRow.click()
        XCTAssertTrue(app.columnNameFields.element(boundBy: 2).waitForExistence(timeout: 2))
        sleep(1)
        XCTAssertEqual(app.columnNameFields.count, 3)
    }

    /// Double-clicking the hint row must add one column, not one per click.
    @MainActor
    func testDoubleClickingHintRowAddsOneColumn() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        app.addColumnRow.doubleClick()
        sleep(1)
        XCTAssertEqual(app.columnNameFields.count, 3)
    }

    @MainActor
    func testDoubleClickingEmptyRowAddsColumnButSingleClickDoesNot() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        let filler = app.fillerRows.element(boundBy: 2)

        filler.click()
        sleep(1)
        XCTAssertEqual(app.columnNameFields.count, 2, "a single click on an empty row shouldn't add a column")

        filler.doubleClick()
        sleep(1)
        XCTAssertEqual(app.columnNameFields.count, 3)
    }

    /// Inside the editor ⌘N adds a column; the sheet's shortcut wins over File → New Database.
    @MainActor
    func testCommandNAddsColumnInsideEditor() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        app.typeKey("n", modifierFlags: .command)
        sleep(1)
        XCTAssertEqual(app.columnNameFields.count, 3)
        XCTAssertFalse(app.dialogs.firstMatch.exists, "⌘N opened the new database panel instead")
    }

    @MainActor
    func testCommandSSaves() throws {
        try assertSaves(withCommand: "s")
    }

    @MainActor
    func testCommandReturnSaves() throws {
        try assertSaves(withCommand: XCUIKeyboardKey.return.rawValue)
    }

    @MainActor
    func testEscapeCancelsWithoutChanges() throws {
        let (app, path) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        app.typeKey("n", modifierFlags: .command)
        app.typeText("discarded")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.tableNameField.waitForNonExistence(timeout: 5), "esc didn't close the editor")
        XCTAssertEqual(try TestDatabase.columns(path!, "t"), ["id", "name"])
    }

    /// Deleting an existing column only marks it; Save drops it.
    @MainActor
    func testDeleteColumnIsStagedUntilSave() throws {
        let (app, path) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        app.buttons.matching(identifier: "Delete Column").element(boundBy: 1).click()
        XCTAssertEqual(app.columnNameFields.count, 2, "the deleted column should stay visible until Save")
        XCTAssertTrue(app.buttons["Restore Column"].exists)
        XCTAssertEqual(try TestDatabase.columns(path!, "t"), ["id", "name"])

        app.buttons["Save"].click()
        XCTAssertTrue(app.tableNameField.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try TestDatabase.columns(path!, "t"), ["id"])
    }

    @MainActor
    func testDeleteTableFromEditor() throws {
        let (app, path) = try XCUIApplication.launched(withDatabase: Self.schema + "CREATE TABLE other (x);")
        app.openStructureEditor(for: "t")
        app.buttons["Delete Table…"].click()
        // Scoped to the window: the Touch Bar has a copy of the button.
        app.windows.firstMatch.buttons["Delete Table"].firstMatch.click()
        XCTAssertTrue(app.tableNameField.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try TestDatabase.tables(path!), ["other"])
    }

    /// Adds a column, saves with ⌘ + `key`, and checks the editor closed and the column exists.
    @MainActor
    private func assertSaves(withCommand key: String, line: UInt = #line) throws {
        let (app, path) = try XCUIApplication.launched(withDatabase: Self.schema)
        app.openStructureEditor(for: "t")
        app.typeKey("n", modifierFlags: .command)
        app.typeText("added")
        app.typeKey(key, modifierFlags: .command)
        XCTAssertTrue(app.tableNameField.waitForNonExistence(timeout: 5), "editor stayed open", line: line)
        XCTAssertEqual(try TestDatabase.columns(path!, "t"), ["id", "name", "added"], line: line)
    }
}
