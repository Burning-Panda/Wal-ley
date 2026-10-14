import Foundation
import GRDB
import Testing
@testable import wal_ley

@MainActor
struct SchemaEditingTests {
    private func makeDatabase(_ sql: String) async throws -> (DatabaseManager, DatabaseQueue) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { try $0.execute(sql: sql) }
        let manager = DatabaseManager()
        await manager.open(url)
        #expect(manager.isOpen)
        return (manager, queue)
    }

    private func draft(_ manager: DatabaseManager, _ table: String) throws -> TableDraft {
        try TableDraft(#require(manager.tables.first { $0.name == table }))
    }

    private func spec(_ manager: DatabaseManager, _ table: String, _ column: String) throws -> ColumnSpec? {
        try draft(manager, table).columns.first { $0.spec.name == column }?.spec
    }

    private func edit(_ draft: inout TableDraft, _ column: String, _ change: (inout ColumnSpec) -> Void) {
        let index = draft.columns.firstIndex { $0.spec.name == column }!
        change(&draft.columns[index].spec)
    }

    @Test func createTableWithColumns() async throws {
        let (manager, _) = try await makeDatabase("CREATE TABLE a (x)")
        var draft = TableDraft()
        draft.name = "people"
        draft.columns.append(ColumnDraft(spec: ColumnSpec(name: "email", type: "TEXT", notNull: true, unique: true), original: nil))
        draft.columns.append(ColumnDraft(spec: ColumnSpec(name: "age", type: "INTEGER", defaultValue: "0"), original: nil))
        try await manager.saveStructure(draft)

        #expect(try spec(manager, "people", "id")?.primaryKey == true)
        #expect(try spec(manager, "people", "email") == ColumnSpec(name: "email", type: "TEXT", notNull: true, unique: true))
        #expect(try spec(manager, "people", "age")?.defaultValue == "0")

        try await manager.deleteTable("people")
        #expect(!manager.tables.contains { $0.name == "people" })
    }

    @Test func renamesDropsAndAddsWithoutRebuild() async throws {
        let (manager, queue) = try await makeDatabase("""
            CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT);
            CREATE INDEX t_a ON t(a);
            INSERT INTO t VALUES (1, 'x', 'y');
            """)
        var draft = try draft(manager, "t")
        draft.name = "renamed"
        edit(&draft, "a") { $0.name = "alpha" }
        draft.columns[draft.columns.firstIndex { $0.spec.name == "b" }!].deleted = true
        draft.columns.append(ColumnDraft(spec: ColumnSpec(name: "c", type: "REAL"), original: nil))
        try await manager.saveStructure(draft)

        let saved = try self.draft(manager, "renamed")
        #expect(saved.columns.map(\.spec.name) == ["id", "alpha", "c"])
        try await queue.read { db throws in
            #expect(try String.fetchOne(db, sql: "SELECT alpha FROM renamed") == "x")
            #expect(try db.indexes(on: "renamed").first?.columns == ["alpha"])
        }
    }

    @Test func rebuildKeepsRowsIndexesTriggersAndRowids() async throws {
        let (manager, queue) = try await makeDatabase("""
            CREATE TABLE t (name TEXT COLLATE NOCASE, price TEXT CHECK (price <> ''));
            CREATE INDEX t_name ON t(name);
            CREATE TABLE log (msg);
            CREATE TRIGGER t_ins AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.name); END;
            CREATE VIEW v AS SELECT name FROM t;
            INSERT INTO t (rowid, name, price) VALUES (10, 'a', '1.5'), (20, 'b', '2');
            """)
        var draft = try draft(manager, "t")
        edit(&draft, "price") { $0.type = "REAL"; $0.notNull = true; $0.defaultValue = "1" }
        draft.columns.append(ColumnDraft(spec: ColumnSpec(name: "code", unique: true), original: nil))
        try await manager.saveStructure(draft)

        #expect(try spec(manager, "t", "price") == ColumnSpec(name: "price", type: "REAL", notNull: true, defaultValue: "1"))
        #expect(try spec(manager, "t", "code")?.unique == true)
        try await queue.write { db throws in
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 't'") ?? ""
            #expect(sql.contains("COLLATE NOCASE"))
            let rows = try Row.fetchAll(db, sql: "SELECT rowid, typeof(price) AS kind FROM t ORDER BY rowid")
            #expect(rows.map { $0["rowid"] as Int64 } == [10, 20])
            #expect(rows.allSatisfy { ($0["kind"] as String) == "real" })
            #expect(try db.indexes(on: "t").contains { $0.name == "t_name" })
            #expect(try String.fetchAll(db, sql: "SELECT name FROM v").count == 2)
            // The trigger fired for the two seed rows only (not for the copy), and still fires.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM log") == 2)
            try db.execute(sql: "INSERT INTO t (name, price) VALUES ('c', 3)")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM log") == 3)
            #expect(throws: (any Error).self) { try db.execute(sql: "INSERT INTO t (name, price) VALUES ('d', '')") }
        }
    }

    @Test func movesPrimaryKeyAndRemovesUnique() async throws {
        let (manager, _) = try await makeDatabase("""
            CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT, tag TEXT, UNIQUE (tag));
            INSERT INTO t (code, tag) VALUES ('a', 'x'), ('b', 'y');
            """)
        var draft = try draft(manager, "t")
        #expect(draft.columns.first { $0.spec.name == "tag" }?.spec.unique == true)
        edit(&draft, "id") { $0.primaryKey = false }
        edit(&draft, "code") { $0.primaryKey = true }
        edit(&draft, "tag") { $0.unique = false }
        try await manager.saveStructure(draft)

        #expect(try spec(manager, "t", "id")?.primaryKey == false)
        #expect(try spec(manager, "t", "code")?.primaryKey == true)
        #expect(try spec(manager, "t", "tag")?.unique == false)

        var composite = try self.draft(manager, "t")
        edit(&composite, "tag") { $0.primaryKey = true }
        try await manager.saveStructure(composite)
        #expect(try spec(manager, "t", "code")?.primaryKey == true)
        #expect(try spec(manager, "t", "tag")?.primaryKey == true)
    }

    @Test func failedSaveChangesNothing() async throws {
        let (manager, _) = try await makeDatabase("CREATE TABLE t (id INTEGER PRIMARY KEY, x); INSERT INTO t (x) VALUES (NULL)")
        var draft = try draft(manager, "t")
        draft.name = "renamed"
        edit(&draft, "x") { $0.notNull = true }  // the existing NULL makes the rebuild fail
        await #expect(throws: (any Error).self) { try await manager.saveStructure(draft) }
        #expect(manager.tables.map(\.name) == ["t"])
        #expect(try spec(manager, "t", "x")?.notNull == false)
    }

    @Test func createsEmptyDatabaseAndOpensIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("new-\(UUID().uuidString).sqlite")
        let manager = DatabaseManager()
        await manager.createDatabase(at: url)
        #expect(manager.isOpen)
        #expect(manager.tables.isEmpty)
        let header = try FileHandle(forReadingFrom: url).read(upToCount: 16)
        #expect(header == Data("SQLite format 3\0".utf8))
    }

    @Test func refusesPathWithLeftoverWAL() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("new-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: url.path + "-wal", contents: Data())
        let manager = DatabaseManager()
        await manager.createDatabase(at: url)
        #expect(!manager.isOpen)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(manager.errorMessage?.contains("-wal") == true)
    }
}
