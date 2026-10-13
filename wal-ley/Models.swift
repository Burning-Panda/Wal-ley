import Foundation

nonisolated struct SchemaColumn: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let type: String
    let notNull: Bool
    let primaryKey: Bool
}

nonisolated struct SchemaIndex: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let unique: Bool
    let columns: [String]
}

nonisolated struct SchemaTable: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isView: Bool
    let columns: [SchemaColumn]
    let indexes: [SchemaIndex]
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
