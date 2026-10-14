import Foundation
import GRDB
import Observation
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class DatabaseManager {
    nonisolated static let pageSize = 200
    nonisolated static let consoleRowLimit = 1000

    // MARK: State

    var showOpenPanel = false
    /// Opens the structure editor for a new table.
    var showNewTable = false
    private(set) var isOpen = false
    private(set) var isReadOnly = false
    private(set) var metadata: FileMetadata?
    private(set) var tables: [SchemaTable] = []
    var errorMessage: String?

    var selection: SidebarItem? {
        didSet { if selection != oldValue { selectionChanged() } }
    }

    // Table browsing
    private(set) var grid = GridData()
    private(set) var sort: SortState?
    private(set) var filters: [ColumnFilter] = []
    /// Columns chosen for display; nil means all. Ignored for hand-written queries.
    private(set) var selectedColumns: Set<String>?
    /// A hand-written SELECT. When set it replaces `filters`; the grid pages and sorts it but can't edit it.
    private(set) var rawQuery: String?
    private(set) var page = 0
    private(set) var totalRows = 0
    private(set) var isEditable = false
    private(set) var isLoading = false
    private(set) var pendingChanges: [CellKey: String] = [:]
    private(set) var pendingDeletes: Set<RowKey> = []
    private(set) var recents: [URL] = []

    /// Set while the user is asked what to do with unsaved changes before `action` can run.
    var unsavedPrompt: (() async -> Void)?

    var pendingCount: Int { pendingChanges.count + pendingDeletes.count }

    // Console
    var consoleSQL = "" { didSet { languageService.text = consoleSQL } }
    private(set) var consoleGrid = GridData()
    private(set) var consoleStatus: String?
    private(set) var consoleError: String?
    private(set) var consoleRunning = false
    let languageService = SQLLanguageService()

    @ObservationIgnored private var queue: DatabaseQueue?
    @ObservationIgnored private var openURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var versionCounter = 0

    var selectedTable: SchemaTable? {
        guard case .table(let name)? = selection else { return nil }
        return tables.first { $0.name == name }
    }

    /// Chosen columns in schema order, or nil when every column is shown.
    var columnList: [String]? {
        guard let selectedColumns, let table = selectedTable else { return nil }
        let names = table.columns.map(\.name).filter(selectedColumns.contains)
        return names.count == table.columns.count || names.isEmpty ? nil : names
    }

    func isColumnSelected(_ name: String) -> Bool { selectedColumns?.contains(name) ?? true }

    func setColumn(_ name: String, selected: Bool) {
        guard let table = selectedTable else { return }
        var set = selectedColumns ?? Set(table.columns.map(\.name))
        if selected { set.insert(name) } else if set.count > 1 { set.remove(name) }  // keep at least one
        selectedColumns = set.count == table.columns.count ? nil : set
        reload()
    }

    func showAllColumns() {
        selectedColumns = nil
        reload()
    }

    /// The query the grid is showing, as SQL text. Builder values are inlined for display only; the real query
    /// binds them as parameters. Paging is applied on top and is not part of this text.
    var generatedQuery: String {
        if let rawQuery { return rawQuery }
        guard let table = selectedTable else { return "" }
        let list = columnList?.map(sqlQuote).joined(separator: ", ") ?? "*"
        var sql = "SELECT \(list) FROM \(sqlQuote(table.name))"
        if !filters.isEmpty { sql += " WHERE " + filters.map(\.displayClause).joined(separator: " AND ") }
        if let sort { sql += " ORDER BY \(sqlQuote(sort.column)) \(sort.ascending ? "ASC" : "DESC")" }
        return sql
    }

    var queryPreview: String { generatedQuery + " LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)" }

    var pageCount: Int { max(1, (totalRows + Self.pageSize - 1) / Self.pageSize) }

    init() { refreshRecents() }

    // MARK: Opening / closing

    /// Runs `action` now, or after the user resolves unsaved changes.
    func guardUnsaved(_ action: @escaping () async -> Void) async {
        if pendingCount == 0 { await action() } else { unsavedPrompt = action }
    }

    func requestOpen(_ url: URL) async { await guardUnsaved { await self.open(url) } }
    func requestClose() async { await guardUnsaved { self.close() } }
    func requestNewDatabase() async { await guardUnsaved { await self.chooseNewDatabaseLocation() } }

    private func chooseNewDatabaseLocation() async {
        let panel = NSSavePanel()
        panel.title = "New Database"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .database]
        panel.canCreateDirectories = true
        // The panel asks before replacing an existing file.
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        await createDatabase(at: url)
    }

    /// Creates an empty database at `url` and opens it. A file already there goes to the Trash.
    func createDatabase(at url: URL) async {
        let files = FileManager.default
        // A leftover WAL from an earlier database at this path could be replayed into the new one.
        for suffix in ["-wal", "-shm"] where files.fileExists(atPath: url.path + suffix) {
            errorMessage = "Couldn't create “\(url.lastPathComponent)”: “\(url.lastPathComponent + suffix)” is next to it "
                + "and could corrupt the new database. Move it away or choose another name."
            return
        }
        do {
            if files.fileExists(atPath: url.path) {
                if openURL?.standardizedFileURL == url.standardizedFileURL { close() }
                try files.trashItem(at: url, resultingItemURL: nil)
            }
            // A write makes SQLite put its header in the file; an empty file isn't recognised as a database.
            let queue = try DatabaseQueue(path: url.path)
            try await queue.write { try $0.execute(sql: "PRAGMA user_version = 0") }
            try queue.close()
        } catch {
            errorMessage = "Couldn't create “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        await requestOpen(url)
    }

    func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecents()
    }

    func close() {
        loadTask?.cancel()
        queue = nil
        openURL = nil
        isOpen = false
        isReadOnly = false
        metadata = nil
        tables = []
        languageService.update(tables: [])
        grid = GridData()
        consoleGrid = GridData()
        consoleStatus = nil
        consoleError = nil
        errorMessage = nil
        totalRows = 0
        isEditable = false
        isLoading = false
        pendingChanges = [:]
        pendingDeletes = []
        selection = nil
    }

    func open(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var readOnly = false
            var queue: DatabaseQueue
            do {
                queue = try DatabaseQueue(path: url.path)
            } catch {
                var config = Configuration()
                config.readonly = true
                queue = try DatabaseQueue(path: url.path, configuration: config)
                readOnly = true
            }
            // Doubles as validation: a non-database file fails here.
            let schema = try await Self.loadSchema(queue)

            loadTask?.cancel()
            self.queue = queue
            openURL = url
            isOpen = true
            isReadOnly = readOnly
            tables = schema
            languageService.update(tables: schema)
            metadata = Self.metadata(for: url)
            pendingChanges = [:]
            pendingDeletes = []
            grid = GridData()
            consoleGrid = GridData()
            consoleStatus = nil
            consoleError = nil
            errorMessage = nil
            selection = nil
            selection = schema.first.map { .table($0.name) }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            refreshRecents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func metadata(for url: URL) -> FileMetadata {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileMetadata(
            name: url.lastPathComponent,
            directory: url.deletingLastPathComponent().path,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate
        )
    }

    nonisolated private static func loadSchema(_ queue: DatabaseQueue) async throws -> [SchemaTable] {
        try await queue.read { db in
            let objects = try Row.fetchAll(db, sql: """
                SELECT name, type FROM sqlite_master
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            return try objects.map { row in
                let name: String = row["name"]
                let type: String = row["type"]
                let columns = try db.columns(in: name).map {
                    SchemaColumn(name: $0.name, type: $0.type, notNull: $0.isNotNull, primaryKey: $0.primaryKeyIndex > 0,
                                 defaultValue: $0.defaultValueSQL)
                }
                let indexes = ((try? db.indexes(on: name)) ?? []).map {
                    SchemaIndex(name: $0.name, unique: $0.isUnique, columns: $0.columns, isConstraint: $0.origin != .createIndex)
                }
                return SchemaTable(name: name, isView: type == "view", columns: columns, indexes: indexes)
            }
        }
    }

    // MARK: Selection / mode

    private func selectionChanged() {
        loadTask?.cancel()
        isLoading = false
        sort = nil
        filters = []
        rawQuery = nil
        selectedColumns = nil
        page = 0
        switch selection {
        case .table:
            reload()
        case .console, nil:
            // Console is its own mode: no table data, no selected table.
            grid = GridData()
            totalRows = 0
            isEditable = false
        }
    }

    // MARK: Browsing

    func setSort(column: String, ascending: Bool) {
        sort = SortState(column: column, ascending: ascending)
        page = 0
        reload()
    }

    func addFilter(_ filter: ColumnFilter) {
        rawQuery = nil
        filters.append(filter)
        page = 0
        reload()
    }

    /// Runs a hand-written SELECT in the grid (empty clears it). Replaces any builder filters.
    func setRawQuery(_ text: String?) {
        var trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        filters = []
        rawQuery = trimmed.isEmpty ? nil : trimmed
        page = 0
        reload()
    }

    func removeFilter(_ filter: ColumnFilter) {
        filters.removeAll { $0.id == filter.id }
        page = 0
        reload()
    }

    func goToPage(_ newPage: Int) {
        let clamped = min(max(0, newPage), pageCount - 1)
        guard clamped != page else { return }
        page = clamped
        reload()
    }

    func reload() {
        guard let queue, let table = selectedTable else { return }
        loadTask?.cancel()
        let (sort, filters, rawQuery, columns, page) = (self.sort, self.filters, self.rawQuery, self.columnList, self.page)
        isLoading = true
        loadTask = Task {
            do {
                let result = try await Self.fetchPage(queue, table: table.name, isView: table.isView,
                                                     sort: sort, filters: filters, rawQuery: rawQuery, columns: columns, page: page)
                guard !Task.isCancelled else { return }
                grid = stamped(result.grid)
                totalRows = result.total
                isEditable = result.editable && !isReadOnly
                errorMessage = nil
                // Rows were deleted from the last page: step back.
                if result.grid.rows.isEmpty, page > 0, result.total > 0 {
                    self.page = (result.total - 1) / Self.pageSize
                    reload()
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func stamped(_ grid: GridData) -> GridData {
        versionCounter += 1
        var grid = grid
        grid.version = versionCounter
        return grid
    }

    nonisolated private static func fetchPage(
        _ queue: DatabaseQueue, table: String, isView: Bool,
        sort: SortState?, filters: [ColumnFilter], rawQuery: String?, columns: [String]?, page: Int
    ) async throws -> (grid: GridData, total: Int, editable: Bool) {
        try await queue.read { db in
            // A hand-written query is wrapped as a subquery so paging and sorting still happen in SQL.
            // The newline keeps a trailing `--` comment from swallowing the closing parenthesis.
            let from = rawQuery.map { "(\($0)\n)" } ?? sqlQuote(table)
            var clauses: [String] = []
            var arguments: [DatabaseValueConvertible?] = []
            for filter in filters {
                let clause = filter.clause()
                clauses.append(clause.sql)
                if let argument = clause.argument { arguments.append(argument) }
            }
            let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let orderSQL = sort.map { " ORDER BY \(sqlQuote($0.column)) \($0.ascending ? "ASC" : "DESC")" } ?? ""

            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(from)\(whereSQL)",
                                         arguments: StatementArguments(arguments)) ?? 0

            // Rows are addressable by rowid, except views and WITHOUT ROWID tables.
            // Raw queries run in a read transaction, so they can read but never modify.
            let hasRowID = rawQuery == nil && !isView && (try? db.makeStatement(sql: "SELECT rowid FROM \(from) LIMIT 0")) != nil
            let list = rawQuery == nil ? (columns?.map(sqlQuote).joined(separator: ", ") ?? "*") : "*"
            let select = hasRowID ? "rowid AS \"__rowid__\", \(list)" : list

            let statement = try db.makeStatement(
                sql: "SELECT \(select) FROM \(from)\(whereSQL)\(orderSQL) LIMIT ? OFFSET ?")
            let paged = arguments + [pageSize, page * pageSize]
            let rows = try Row.fetchAll(statement, arguments: StatementArguments(paged))

            let skip = hasRowID ? 1 : 0
            let names = statement.columnNames
            var grid = GridData()
            grid.columns = Array(names.dropFirst(skip))
            grid.rowIDs = hasRowID ? rows.map { $0[0] as Int64 } : []
            grid.rows = rows.map { row in (skip..<names.count).map { display(row[$0]) } }
            return (grid, total, hasRowID)
        }
    }

    nonisolated private static func display(_ value: DatabaseValue) -> String {
        switch value.storage {
        case .null: "NULL"
        case .int64(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        case .blob(let d): "<blob \(d.count) bytes>"
        }
    }

    // MARK: Editing

    /// Records an edit in `pendingChanges`; nothing touches the database until `saveChanges()`.
    func edit(row: Int, column: String, newValue: String) {
        guard isEditable, let table = selectedTable,
              row < grid.rowIDs.count, row < grid.rows.count,
              let index = grid.columns.firstIndex(of: column) else { return }
        let original = grid.rows[row][index]
        guard !original.hasPrefix("<blob ") else { return }
        let key = CellKey(table: table.name, rowID: grid.rowIDs[row], column: column)
        pendingChanges[key] = newValue == original ? nil : newValue
    }

    /// Marks rows (by position on the current page) for deletion; applied on Save.
    func deleteRows(_ rows: IndexSet) {
        guard isEditable, let table = selectedTable else { return }
        for row in rows where row < grid.rowIDs.count {
            let id = grid.rowIDs[row]
            pendingDeletes.insert(RowKey(table: table.name, rowID: id))
            pendingChanges = pendingChanges.filter { !($0.key.table == table.name && $0.key.rowID == id) }
        }
    }

    func restoreRows(_ rows: IndexSet) {
        guard let table = selectedTable else { return }
        for row in rows where row < grid.rowIDs.count {
            pendingDeletes.remove(RowKey(table: table.name, rowID: grid.rowIDs[row]))
        }
    }

    func isDeleted(row: Int) -> Bool {
        guard let table = selectedTable, row < grid.rowIDs.count else { return false }
        return pendingDeletes.contains(RowKey(table: table.name, rowID: grid.rowIDs[row]))
    }

    func saveChanges() async {
        guard let queue, pendingCount > 0 else { return }
        let changes = pendingChanges
        let deletes = pendingDeletes
        do {
            // One transaction: either every change lands or none does.
            try await queue.write { db in
                for key in deletes {
                    try db.execute(sql: "DELETE FROM \(sqlQuote(key.table)) WHERE rowid = ?", arguments: [key.rowID])
                }
                for (key, value) in changes {
                    let stored: DatabaseValueConvertible? = value == "NULL" ? nil : value
                    try db.execute(
                        sql: "UPDATE \(sqlQuote(key.table)) SET \(sqlQuote(key.column)) = ? WHERE rowid = ?",
                        arguments: [stored, key.rowID])
                }
            }
            pendingChanges = [:]
            pendingDeletes = []
            errorMessage = nil
            reload()
        } catch {
            errorMessage = "Save failed, nothing was written: \(error.localizedDescription)"
        }
    }

    func discardChanges() {
        pendingChanges = [:]
        pendingDeletes = []
    }

    // MARK: Schema editing

    /// Drops a table, or a view when `name` is one.
    func deleteTable(_ name: String) async throws {
        let isView = tables.first { $0.name == name }?.isView ?? false
        try await alterSchema(of: name) { db in
            try db.execute(sql: "DROP \(isView ? "VIEW" : "TABLE") \(sqlQuote(name))")
        }
    }

    /// Applies the structure editor's draft in one transaction: creates the table, or alters it to match.
    func saveStructure(_ draft: TableDraft) async throws {
        if let problem = draft.problem { throw SchemaError(problem) }
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        for i in draft.columns.indices { draft.columns[i].spec.name = draft.columns[i].spec.name.trimmingCharacters(in: .whitespaces) }
        let final = draft
        try await alterSchema(of: draft.original ?? draft.name, renamedTo: draft.name) { db in
            if final.original == nil {
                try db.execute(sql: Self.createSQL(final))
            } else {
                try Self.withForeignKeysOff(db) {
                    try db.inTransaction {
                        try Self.alter(db, to: final)
                        return .commit
                    }
                }
            }
        }
    }

    nonisolated private static func createSQL(_ draft: TableDraft) -> String {
        var definition = TableDefinition()
        for column in draft.live { definition.insertColumn(columnSQL(column.spec)) }
        setPrimaryKey(&definition, draft.live.filter(\.spec.primaryKey).map(\.spec.name))
        return definition.createSQL(name: draft.name)
    }

    /// A new column's definition. The primary key is placed separately since it may span columns.
    nonisolated private static func columnSQL(_ spec: ColumnSpec) -> String {
        var clauses = ColumnClauses(name: sqlQuote(spec.name), type: spec.type)
        if spec.notNull { clauses.set(.notNull, "NOT NULL") }
        if spec.unique { clauses.set(.unique, "UNIQUE") }
        if let value = spec.defaultSQL { clauses.set(.defaultValue, "DEFAULT \(value)") }
        return clauses.sql
    }

    /// One column keeps its key inline (so INTEGER stays a rowid alias); several get a table constraint.
    nonisolated private static func setPrimaryKey(_ definition: inout TableDefinition, _ columns: [String]) {
        for name in definition.columnNames { definition.update(column: name) { $0.set(.primaryKey, nil) } }
        definition.removeTableConstraints(.primaryKey)
        if columns.count == 1 {
            definition.update(column: columns[0]) { $0.set(.primaryKey, "PRIMARY KEY") }
        } else if columns.count > 1 {
            definition.definitions.append("PRIMARY KEY (\(columns.map(sqlQuote).joined(separator: ", ")))")
        }
    }

    /// Drops, renames and simple additions use ALTER TABLE, which also updates indexes, triggers and views.
    /// Anything ALTER TABLE can't do (types, constraints, defaults) is applied by one rebuild at the end.
    nonisolated private static func alter(_ db: Database, to draft: TableDraft) throws {
        guard let original = draft.original else { return }
        for column in draft.columns where column.deleted {
            guard let old = column.original else { continue }
            try db.execute(sql: "ALTER TABLE \(sqlQuote(original)) DROP COLUMN \(sqlQuote(old.name))")
        }
        for column in draft.live {
            guard let old = column.original, old.name != column.spec.name else { continue }
            try db.execute(sql: "ALTER TABLE \(sqlQuote(original)) RENAME COLUMN \(sqlQuote(old.name)) TO \(sqlQuote(column.spec.name))")
        }
        if draft.name != original {
            try db.execute(sql: "ALTER TABLE \(sqlQuote(original)) RENAME TO \(sqlQuote(draft.name))")
        }

        let added = draft.live.filter(\.isNew)
        let changed = draft.live.filter { column in
            guard let old = column.original else { return false }
            var renamed = old
            renamed.name = column.spec.name
            return renamed != column.spec
        }
        let keyChanged = draft.columns.contains { column in
            column.deleted ? column.original?.primaryKey == true : column.spec.primaryKey != (column.original?.primaryKey ?? false)
        }
        // ADD COLUMN can't add a key or UNIQUE, nor NOT NULL without a default.
        let needsRebuild = keyChanged || !changed.isEmpty
            || added.contains { $0.spec.unique || ($0.spec.notNull && $0.spec.defaultSQL == nil) }

        guard needsRebuild else {
            for column in added {
                try db.execute(sql: "ALTER TABLE \(sqlQuote(draft.name)) ADD COLUMN \(columnSQL(column.spec))")
            }
            return
        }
        try rebuild(db, table: draft.name) { definition in
            for column in changed {
                let old = column.original!, new = column.spec
                definition.update(column: new.name) { clauses in
                    if new.type != old.type { clauses.type = new.type }
                    if new.notNull != old.notNull { clauses.set(.notNull, new.notNull ? "NOT NULL" : nil) }
                    if new.unique != old.unique { clauses.set(.unique, new.unique ? "UNIQUE" : nil) }
                    if new.defaultValue != old.defaultValue { clauses.set(.defaultValue, new.defaultSQL.map { "DEFAULT \($0)" }) }
                }
                if old.unique && !new.unique { definition.removeTableConstraints(.unique, columns: [new.name]) }
            }
            for column in added { definition.insertColumn(columnSQL(column.spec)) }
            if keyChanged { setPrimaryKey(&definition, draft.live.filter(\.spec.primaryKey).map(\.spec.name)) }
        }
    }

    /// Runs a schema change, then reloads the schema. The open table is reset because its filters, sort and
    /// column choice may name columns that no longer exist.
    private func alterSchema(
        of table: String, renamedTo newName: String? = nil, _ change: @escaping @Sendable (Database) throws -> Void
    ) async throws {
        guard let queue, !isReadOnly else { throw SchemaError("The database is read-only.") }
        try await queue.writeWithoutTransaction { db in
            try change(db)
            db.clearSchemaCache()
        }
        tables = try await Self.loadSchema(queue)
        languageService.update(tables: tables)
        if selection == .table(table) {
            let current = newName ?? table
            if !tables.contains(where: { $0.name == current }) {
                selection = nil
            } else if current != table {
                selection = .table(current)
            } else {
                selectionChanged()
            }
        }
    }

    /// Foreign key enforcement can only be switched outside a transaction. Off, rebuilding a table doesn't
    /// cascade or fail on rows that reference it.
    nonisolated private static func withForeignKeysOff(_ db: Database, _ work: () throws -> Void) throws {
        let enabled = try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        defer { if enabled { try? db.execute(sql: "PRAGMA foreign_keys = ON") } }
        try work()
        if enabled, try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") != nil {
            throw SchemaError("The change broke a foreign key.")
        }
    }

    /// SQLite can't change a column definition in place. This is its documented rebuild, run inside the
    /// caller's transaction: create the new shape under a temporary name, copy the rows, swap it in, and
    /// restore the table's indexes and triggers.
    nonisolated private static func rebuild(
        _ db: Database, table: String, edit: (inout TableDefinition) throws -> Void
    ) throws {
        guard let sql = try String.fetchOne(
                  db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [table]),
              var definition = TableDefinition(sql: sql)
        else { throw SchemaError("Couldn't read the definition of “\(table)”.") }
        try edit(&definition)

        let temp = table + "__wal_ley_rebuild"
        let dependents = try String.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL
            """, arguments: [table])
        try db.execute(sql: definition.createSQL(name: temp))

        let old = try storedColumns(db, table)
        let shared = try storedColumns(db, temp).filter(old.contains)
        if !shared.isEmpty {
            var list = shared.map(sqlQuote).joined(separator: ", ")
            // Keep rowids stable unless the new table has an INTEGER PRIMARY KEY, which already is the rowid.
            if try hasRowID(db, table), try hasRowID(db, temp), try !hasRowIDAlias(db, temp) {
                list = "rowid, " + list
            }
            try db.execute(sql: "INSERT INTO \(sqlQuote(temp)) (\(list)) SELECT \(list) FROM \(sqlQuote(table))")
        }
        try db.execute(sql: "DROP TABLE \(sqlQuote(table))")
        // Legacy rename leaves references in other tables and views pointing at the original name, which is
        // where the rebuilt table ends up.
        try db.execute(sql: "PRAGMA legacy_alter_table = ON")
        defer { try? db.execute(sql: "PRAGMA legacy_alter_table = OFF") }
        try db.execute(sql: "ALTER TABLE \(sqlQuote(temp)) RENAME TO \(sqlQuote(table))")
        for sql in dependents { try db.execute(sql: sql) }
    }

    /// Columns that hold data; generated columns compute themselves and can't be inserted into.
    nonisolated private static func storedColumns(_ db: Database, _ table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_xinfo(\(sqlQuote(table)))")
            .filter { ($0["hidden"] as Int) == 0 }
            .map { $0["name"] }
    }

    nonisolated private static func hasRowID(_ db: Database, _ table: String) throws -> Bool {
        (try? db.makeStatement(sql: "SELECT rowid FROM \(sqlQuote(table)) LIMIT 0")) != nil
    }

    nonisolated private static func hasRowIDAlias(_ db: Database, _ table: String) throws -> Bool {
        let keys = try Row.fetchAll(db, sql: "PRAGMA table_info(\(sqlQuote(table)))").filter { ($0["pk"] as Int) > 0 }
        return keys.count == 1 && (keys[0]["type"] as String).uppercased() == "INTEGER"
    }

    // MARK: Console

    func runConsole(_ sql: String) async {
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let queue, !text.isEmpty, !consoleRunning else { return }
        consoleRunning = true
        defer { consoleRunning = false }
        let start = ContinuousClock.now
        do {
            let result = try await Self.execute(queue, sql: text, readOnly: isReadOnly)
            let ms = (ContinuousClock.now - start) / .milliseconds(1)
            consoleGrid = stamped(result.grid)
            consoleError = nil
            if result.grid.columns.isEmpty {
                consoleStatus = "OK · \(result.changes) rows changed · \(Int(ms)) ms"
            } else {
                let limited = result.truncated ? " (limited to \(Self.consoleRowLimit))" : ""
                consoleStatus = "\(result.grid.rows.count) rows\(limited) · \(Int(ms)) ms"
            }
            // The statement may have changed the schema.
            tables = try await Self.loadSchema(queue)
            languageService.update(tables: tables)
        } catch {
            consoleError = error.localizedDescription
            consoleStatus = nil
        }
    }

    nonisolated private static func execute(
        _ queue: DatabaseQueue, sql: String, readOnly: Bool
    ) async throws -> (grid: GridData, truncated: Bool, changes: Int) {
        @Sendable func run(_ db: Database) throws -> (GridData, Bool, Int) {
            let statement = try db.makeStatement(sql: sql)
            var grid = GridData()
            grid.columns = statement.columnNames
            var truncated = false
            let cursor = try Row.fetchCursor(statement)
            while let row = try cursor.next() {
                if grid.rows.count >= consoleRowLimit { truncated = true; break }
                grid.rows.append((0..<grid.columns.count).map { display(row[$0]) })
            }
            return (grid, truncated, db.changesCount)
        }
        // No wrapping transaction, so PRAGMA / VACUUM behave as typed.
        let (grid, truncated, changes) = readOnly
            ? try await queue.read(run)
            : try await queue.writeWithoutTransaction(run)
        return (grid, truncated, changes)
    }
}
