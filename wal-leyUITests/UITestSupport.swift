import XCTest

/// Database files for UI tests, made and read with the system `sqlite3` so the app under test is the only
/// code of ours touching them.
enum TestDatabase {
    static func make(_ sql: String) throws -> String {
        let path = NSTemporaryDirectory() + "ui-\(UUID().uuidString).sqlite"
        _ = try sqlite(path, sql)
        return path
    }

    static func columns(_ path: String, _ table: String) throws -> [String] {
        try sqlite(path, "SELECT name FROM pragma_table_info('\(table)')").split(separator: "\n").map(String.init)
    }

    static func tables(_ path: String) throws -> [String] {
        try sqlite(path, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            .split(separator: "\n").map(String.init)
    }

    private static func sqlite(_ path: String, _ sql: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, sql]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

extension XCUIApplication {
    /// Launches the app, optionally with a database built from `sql` already open.
    @MainActor
    static func launched(withDatabase sql: String? = nil) throws -> (XCUIApplication, String?) {
        let app = XCUIApplication()
        // Opening through Launch Services could hand the file to another installed copy of the app.
        let path = try sql.map(TestDatabase.make)
        // Each test starts from a clean slate, not from windows saved by an earlier run.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        if let path { app.launchArguments += ["-open", path] }
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "no window")
        if path != nil {
            // Tables show as disclosure groups; the sidebar itself exists before any database is open.
            XCTAssertTrue(app.outlines.firstMatch.disclosureTriangles.firstMatch.waitForExistence(timeout: 10), "database didn't open")
        }
        return (app, path)
    }

    /// An open or save panel, shown as a sheet or a window depending on how it was presented.
    @MainActor
    func waitForFilePanel(timeout: TimeInterval = 5) -> Bool {
        sheets.firstMatch.waitForExistence(timeout: timeout) || dialogs.firstMatch.waitForExistence(timeout: 1)
    }

    /// The structure editor's table name field; present only while the editor is open.
    var tableNameField: XCUIElement { textFields.matching(NSPredicate(format: "placeholderValue == 'table_name'")).firstMatch }

    /// One name field per column row in the structure editor.
    var columnNameFields: XCUIElementQuery { textFields.matching(NSPredicate(format: "placeholderValue == 'column_name'")) }

    /// The row under the last column that adds one on click.
    var addColumnRow: XCUIElement { descendants(matching: .any)["addColumnRow"] }

    /// The empty rows below it, which add a column on double-click.
    var fillerRows: XCUIElementQuery { descendants(matching: .any).matching(identifier: "fillerRow") }

    var shortcutHints: XCUIElementQuery { descendants(matching: .any).matching(identifier: "shortcutHint") }

    /// The keys each visible hint badge shows.
    var shortcutHintTexts: [String] { shortcutHints.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label } }

    @MainActor
    func sidebarRow(_ table: String) -> XCUIElement {
        outlines.firstMatch.staticTexts[table]
    }

    @MainActor
    func openStructureEditor(for table: String) {
        XCTAssertTrue(sidebarRow(table).waitForExistence(timeout: 5), "no sidebar row for \(table)")
        sidebarRow(table).rightClick()
        menuItems["Edit Table…"].click()
        XCTAssertTrue(tableNameField.waitForExistence(timeout: 5))
    }
}
