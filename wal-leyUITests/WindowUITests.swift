import XCTest

/// The app has one window: every view shares one `DatabaseManager`, so a second window would mirror the
/// first, sheets included.
final class WindowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRelaunchKeepsOneWindow() throws {
        for _ in 0..<2 {
            let (app, _) = try XCUIApplication.launched()
            XCTAssertEqual(app.windows.count, 1)
            app.terminate()
        }
    }

    /// Opening a file from outside (Finder, `open`) loads it into the existing window.
    @MainActor
    func testOpeningFileReusesWindow() throws {
        let (app, _) = try XCUIApplication.launched()
        let path = try TestDatabase.make("CREATE TABLE opened (id INTEGER PRIMARY KEY);")
        // The app under test sits next to the test runner; naming it avoids any other installed copy.
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("wal-ley.app")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appURL.path, path]
        try open.run()
        open.waitUntilExit()

        XCTAssertTrue(app.sidebarRow("opened").waitForExistence(timeout: 10), "the file didn't open")
        XCTAssertEqual(app.windows.count, 1)
    }

    @MainActor
    func testNewTableSheetAppearsOnce() throws {
        let (app, _) = try XCUIApplication.launched(withDatabase: "CREATE TABLE t (id INTEGER PRIMARY KEY);")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.tableNameField.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 1)
    }
}
