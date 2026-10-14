import Foundation

nonisolated struct SchemaColumn: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Bool
    let defaultValue: String?
}

nonisolated struct SchemaIndex: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let unique: Bool
    let columns: [String]
    /// Created by a UNIQUE or PRIMARY KEY constraint rather than CREATE INDEX.
    let isConstraint: Bool
}

nonisolated struct SchemaTable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isView: Bool
    let columns: [SchemaColumn]
    let indexes: [SchemaIndex]
}

/// Declared types offered when creating or retyping a column; any other declared type is kept as written.
nonisolated enum ColumnType: String, CaseIterable, Identifiable {
    case text = "TEXT"
    case integer = "INTEGER"
    case real = "REAL"
    case numeric = "NUMERIC"
    case blob = "BLOB"

    var id: String { rawValue }
}

/// What the structure editor lets you set on a column.
nonisolated struct ColumnSpec: Hashable, Sendable {
    var name = ""
    var type = ColumnType.text.rawValue
    var primaryKey = false
    var notNull = false
    var unique = false
    /// SQL as stored, e.g. `'abc'` or `0`. Empty means no default.
    var defaultValue = ""

    /// Default as SQL: numbers, keywords, quoted strings and parenthesised expressions as typed, anything else
    /// as a text literal.
    var defaultSQL: String? {
        let value = defaultValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let keywords: Set = ["NULL", "TRUE", "FALSE", "CURRENT_TIME", "CURRENT_DATE", "CURRENT_TIMESTAMP"]
        let verbatim = Double(value) != nil || keywords.contains(value.uppercased())
            || (value.count > 1 && value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("(") && value.hasSuffix(")"))
        return verbatim ? value : sqlLiteral(value)
    }
}

/// One row of the structure editor, staged until Save.
nonisolated struct ColumnDraft: Identifiable, Hashable, Sendable {
    let id = UUID()
    var spec: ColumnSpec
    /// As loaded from the database; nil for a column added in the editor.
    let original: ColumnSpec?
    var deleted = false

    var isNew: Bool { original == nil }
    var isChanged: Bool { original.map { $0 != spec } ?? false }
}

/// The structure editor's state: a new table when `original` is nil, otherwise edits to that table.
nonisolated struct TableDraft: Equatable, Sendable {
    var name = ""
    var original: String?
    var columns: [ColumnDraft] = []

    var live: [ColumnDraft] { columns.filter { !$0.deleted } }

    init() {
        columns = [ColumnDraft(spec: ColumnSpec(name: "id", type: ColumnType.integer.rawValue, primaryKey: true), original: nil)]
    }

    init(_ table: SchemaTable) {
        name = table.name
        original = table.name
        columns = table.columns.map { column in
            let unique = table.indexes.contains { $0.isConstraint && $0.unique && $0.columns == [column.name] }
            let spec = ColumnSpec(
                name: column.name,
                // Standard types are matched case-insensitively; anything else is kept as declared.
                type: ColumnType(rawValue: column.type.uppercased())?.rawValue ?? column.type,
                primaryKey: column.primaryKey, notNull: column.notNull, unique: unique,
                defaultValue: column.defaultValue ?? "")
            return ColumnDraft(spec: spec, original: spec)
        }
    }

    var hasChanges: Bool {
        original == nil || name != original || columns.contains { $0.deleted || $0.isNew || $0.isChanged }
    }

    /// Why the draft can't be saved yet, if it can't.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name the table." }
        if live.isEmpty { return "A table needs at least one column." }
        if live.contains(where: { $0.spec.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return "Every column needs a name." }
        let names = live.map { $0.spec.name.lowercased() }
        if Set(names).count != names.count { return "Column names must be unique." }
        return nil
    }
}

nonisolated struct SchemaError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated struct FileMetadata {
    let name: String
    let directory: String
    let size: Int64
    let modified: Date?
}

/// What the sidebar can select. The console is a mode of its own, never a table.
nonisolated enum SidebarItem: Hashable {
    case console
    case table(String)
}

nonisolated struct SortState: Equatable {
    var column: String
    var ascending: Bool
}

/// One page of display data. `rowIDs` is empty when rows can't be addressed (views, WITHOUT ROWID, console).
nonisolated struct GridData {
    var columns: [String] = []
    var rows: [[String]] = []
    var rowIDs: [Int64] = []
    var version = 0
}

nonisolated struct CellKey: Hashable {
    let table: String
    let rowID: Int64
    let column: String
}

nonisolated struct RowKey: Hashable {
    let table: String
    let rowID: Int64
}

nonisolated enum FilterOperator: String, CaseIterable, Identifiable {
    case contains = "contains"
    case equals = "equals"
    case notEquals = "does not equal"
    case startsWith = "starts with"
    case endsWith = "ends with"
    case greaterThan = "greater than"
    case lessThan = "less than"
    case isNull = "is NULL"
    case isNotNull = "is not NULL"

    var id: String { rawValue }
    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

nonisolated struct ColumnFilter: Identifiable, Hashable {
    let id = UUID()
    var column: String
    var op: FilterOperator
    var value: String

    var label: String { op.needsValue ? "\(column) \(op.rawValue) “\(value)”" : "\(column) \(op.rawValue)" }

    /// The same fragment with its value inlined as a literal. For display and for seeding the SQL editor only;
    /// queries always run with bound parameters.
    var displayClause: String {
        let c = clause()
        guard let argument = c.argument else { return c.sql }
        return c.sql.replacingOccurrences(of: "?", with: sqlLiteral(argument))
    }

    /// A parameterised WHERE fragment; the value is never interpolated into SQL.
    func clause() -> (sql: String, argument: String?) {
        let col = sqlQuote(column)
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        switch op {
        case .contains: return ("\(col) LIKE ? ESCAPE '\\'", "%\(escaped)%")
        case .startsWith: return ("\(col) LIKE ? ESCAPE '\\'", "\(escaped)%")
        case .endsWith: return ("\(col) LIKE ? ESCAPE '\\'", "%\(escaped)")
        case .equals: return ("\(col) = ?", value)
        case .notEquals: return ("\(col) != ?", value)
        case .greaterThan: return ("\(col) > ?", value)
        case .lessThan: return ("\(col) < ?", value)
        case .isNull: return ("\(col) IS NULL", nil)
        case .isNotNull: return ("\(col) IS NOT NULL", nil)
        }
    }
}

nonisolated func sqlLiteral(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
}

nonisolated func sqlQuote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

nonisolated enum FuzzyMatch {
    /// Subsequence match. Higher is better; nil means no match.
    static func score(_ query: String, in candidate: String) -> Int? {
        score(Array(query.lowercased()), inLowercased: Array(candidate.lowercased()))
    }

    /// Allocation-free variant for hot paths (autocomplete): both sides already lowercased.
    static func score(_ q: [Character], inLowercased c: [Character]) -> Int? {
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, previous = -2
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if ci == previous + 1 { score += 5 }
            if ci == 0 { score += 10 } else if !c[ci - 1].isLetter && !c[ci - 1].isNumber { score += 6 }
            previous = ci
            qi += 1
        }
        return qi == q.count ? score * 10 - c.count : nil
    }
}
