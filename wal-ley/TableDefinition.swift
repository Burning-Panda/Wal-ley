import Foundation

/// A `CREATE TABLE` statement split into its column definitions and table constraints, kept exactly as written.
/// Just enough parsing to edit columns during a table rebuild without losing CHECKs, collations, foreign keys
/// or `WITHOUT ROWID`.
nonisolated struct TableDefinition {
    var definitions: [String]
    /// Everything after the closing parenthesis, e.g. ` WITHOUT ROWID` or ` STRICT`.
    var suffix: String

    init(definitions: [String] = [], suffix: String = "") {
        self.definitions = definitions
        self.suffix = suffix
    }

    init?(sql: String) {
        let c = Array(sql)
        var i = 0, depth = 0, start = 0
        var parts: [String] = []
        while i < c.count {
            if let next = SQLText.skipLiteral(c, i) { i = next; continue }
            switch c[i] {
            case "(":
                depth += 1
                if depth == 1 { start = i + 1 }
            case ")":
                depth -= 1
                if depth == 0 {
                    parts.append(String(c[start..<i]))
                    self.init(definitions: parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                              suffix: String(c[(i + 1)...]))
                    return
                }
            case "," where depth == 1:
                parts.append(String(c[start..<i]))
                start = i + 1
            default:
                break
            }
            i += 1
        }
        return nil
    }

    /// One definition per line, so a trailing `--` comment can't swallow the separator.
    func createSQL(name: String) -> String {
        let body = definitions.joined(separator: ",\n  ")
        return "CREATE TABLE \(sqlQuote(name)) (\n  \(body)\n)\(suffix)"
    }

    var columnNames: [String] { definitions.compactMap(ColumnClauses.init).map(\.unquotedName) }

    /// Adds a column definition after the last column, ahead of any table constraints.
    mutating func insertColumn(_ definition: String) {
        let index = definitions.lastIndex { ColumnClauses($0) != nil }.map { $0 + 1 } ?? definitions.count
        definitions.insert(definition, at: index)
    }

    /// Edits one column's definition in place. False when the column isn't found.
    @discardableResult
    mutating func update(column: String, _ edit: (inout ColumnClauses) -> Void) -> Bool {
        for (index, definition) in definitions.enumerated() {
            guard var clauses = ColumnClauses(definition),
                  clauses.unquotedName.caseInsensitiveCompare(column) == .orderedSame else { continue }
            edit(&clauses)
            definitions[index] = clauses.sql
            return true
        }
        return false
    }

    /// Removes table constraints of `kind`; for UNIQUE, only one covering exactly `columns`.
    mutating func removeTableConstraints(_ kind: ColumnClauses.Kind, columns: [String]? = nil) {
        definitions.removeAll { definition in
            guard ColumnClauses(definition) == nil else { return false }
            let c = Array(definition)
            let tokens = SQLText.tokens(c)
            var i = 0
            if SQLText.upper(c, tokens, 0) == "CONSTRAINT" { i = 2 }
            guard ColumnClauses.kind(c, tokens, at: i) == kind else { return false }
            guard let columns else { return true }
            // The parenthesised column list follows the keyword(s).
            guard let group = tokens[i...].first(where: { c[$0.lowerBound] == "(" }) else { return false }
            let inner = String(c[(group.lowerBound + 1)..<(group.upperBound - 1)])
            let names = inner.split(separator: ",").compactMap { ColumnClauses(String($0))?.unquotedName }
            return names.map { $0.lowercased() } == columns.map { $0.lowercased() }
        }
    }
}

/// A column definition taken apart: its name as written, declared type, and each constraint clause.
nonisolated struct ColumnClauses {
    enum Kind { case primaryKey, notNull, unique, defaultValue, other }

    var name: String
    var type: String
    var clauses: [(kind: Kind, sql: String)]

    private static let tableConstraintStarts: Set<String> = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"]
    private static let clauseStarts: Set<String> = [
        "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE", "REFERENCES", "GENERATED", "AS",
    ]
    /// A clause keyword after one of these continues the current clause: `NOT NULL`, `DEFAULT NULL`,
    /// `ON DELETE SET NULL`, `GENERATED ALWAYS AS`.
    private static let continuers: Set<String> = ["NOT", "DEFAULT", "SET", "GENERATED", "ALWAYS"]

    init(name: String, type: String, clauses: [(kind: Kind, sql: String)] = []) {
        self.name = name
        self.type = type
        self.clauses = clauses
    }

    /// Nil for a table constraint.
    init?(_ definition: String) {
        let c = Array(definition)
        let tokens = SQLText.tokens(c)
        guard let first = tokens.first, !Self.tableConstraintStarts.contains(SQLText.upper(c, tokens, 0)) else { return nil }
        name = String(c[first])

        // The type is the words (and one parenthesised size) after the name, up to the first clause.
        var i = 1
        var typeEnd = first.upperBound
        while i < tokens.count {
            let token = tokens[i]
            let isWord = c[token.lowerBound].isLetter || c[token.lowerBound] == "_"
            let isSize = c[token.lowerBound] == "(" && i > 1
            guard (isWord && !Self.clauseStarts.contains(SQLText.upper(c, tokens, i))) || isSize else { break }
            typeEnd = token.upperBound
            i += 1
        }
        let typeStart = i > 1 ? tokens[1].lowerBound : typeEnd
        type = String(c[typeStart..<typeEnd])

        clauses = []
        var start = i
        var j = i
        while j < tokens.count {
            let word = SQLText.upper(c, tokens, j)
            let previous = j > 0 ? SQLText.upper(c, tokens, j - 1) : ""
            let afterConstraintName = j > 1 && SQLText.upper(c, tokens, j - 2) == "CONSTRAINT"
            if j > start, Self.clauseStarts.contains(word), !Self.continuers.contains(previous), !afterConstraintName,
               previous != "CONSTRAINT" {
                clauses.append(Self.clause(c, tokens, start..<j))
                start = j
            }
            j += 1
        }
        if start < tokens.count { clauses.append(Self.clause(c, tokens, start..<tokens.count)) }
    }

    var sql: String { ([name, type] + clauses.map(\.sql)).filter { !$0.isEmpty }.joined(separator: " ") }

    var unquotedName: String {
        switch name.first {
        case "\"", "`", "'":
            let quote = String(name.first!)
            return String(name.dropFirst().dropLast()).replacingOccurrences(of: quote + quote, with: quote)
        case "[":
            return String(name.dropFirst().dropLast())
        default:
            return name
        }
    }

    /// Replaces every clause of `kind` with `sql`, or just removes them when `sql` is nil.
    mutating func set(_ kind: Kind, _ sql: String?) {
        clauses.removeAll { $0.kind == kind }
        guard let sql else { return }
        // Keep the conventional order: PRIMARY KEY, NOT NULL, UNIQUE, then the rest.
        let order: [Kind] = [.primaryKey, .notNull, .unique]
        let rank = order.firstIndex(of: kind) ?? order.count
        let index = clauses.firstIndex { (order.firstIndex(of: $0.kind) ?? order.count) > rank } ?? clauses.count
        clauses.insert((kind, sql), at: index)
    }

    fileprivate static func kind(_ c: [Character], _ tokens: [Range<Int>], at i: Int) -> Kind {
        switch SQLText.upper(c, tokens, i) {
        case "PRIMARY": .primaryKey
        case "NOT" where SQLText.upper(c, tokens, i + 1) == "NULL": .notNull
        case "UNIQUE": .unique
        case "DEFAULT": .defaultValue
        default: .other
        }
    }

    private static func clause(_ c: [Character], _ tokens: [Range<Int>], _ range: Range<Int>) -> (kind: Kind, sql: String) {
        let head = SQLText.upper(c, tokens, range.lowerBound) == "CONSTRAINT" ? range.lowerBound + 2 : range.lowerBound
        let sql = String(c[tokens[range.lowerBound].lowerBound..<tokens[range.upperBound - 1].upperBound])
        return (kind(c, tokens, at: head), sql)
    }
}

/// Lexing shared by the two parsers above.
nonisolated enum SQLText {
    static func upper(_ c: [Character], _ tokens: [Range<Int>], _ i: Int) -> String {
        i < tokens.count ? String(c[tokens[i]]).uppercased() : ""
    }

    /// Words, quoted names, parenthesised groups and single punctuation marks; whitespace and comments dropped.
    static func tokens(_ c: [Character]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var i = 0
        while i < c.count {
            let start = i
            if c[i].isWhitespace { i += 1; continue }
            if let next = skipLiteral(c, i) {
                i = next
                if c[start] == "-" || c[start] == "/" { continue }
            } else if isWordCharacter(c[i]) {
                while i < c.count, isWordCharacter(c[i]) { i += 1 }
            } else if c[i] == "(" {
                var depth = 0
                while i < c.count {
                    if let next = skipLiteral(c, i) { i = next; continue }
                    if c[i] == "(" { depth += 1 }
                    if c[i] == ")" { depth -= 1 }
                    i += 1
                    if depth == 0 { break }
                }
            } else {
                i += 1
            }
            result.append(start..<i)
        }
        return result
    }

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_" || ch == "$"
    }

    /// If a string, quoted name or comment starts at `i`, the index just past it.
    static func skipLiteral(_ c: [Character], _ i: Int) -> Int? {
        let next: Character? = i + 1 < c.count ? c[i + 1] : nil
        switch c[i] {
        case "'", "\"", "`":
            var j = i + 1
            while j < c.count {
                if c[j] == c[i] {
                    if j + 1 < c.count, c[j + 1] == c[i] { j += 2; continue }
                    return j + 1
                }
                j += 1
            }
            return c.count
        case "[":
            return c[(i + 1)...].firstIndex(of: "]").map { $0 + 1 } ?? c.count
        case "-" where next == "-":
            return c[i...].firstIndex(of: "\n") ?? c.count
        case "/" where next == "*":
            var j = i + 2
            while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
            return min(j + 2, c.count)
        default:
            return nil
        }
    }
}
