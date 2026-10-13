import SwiftUI
import Combine
import LanguageSupport

/// Feeds CodeEditorView fuzzy-matched completions for SQL keywords, tables and columns.
final class SQLLanguageService: LanguageService {
    private struct Candidate {
        let name: String
        let kind: String
        let detail: String
        let lowered: [Character]

        init(name: String, kind: String, detail: String) {
            self.name = name
            self.kind = kind
            self.detail = detail
            self.lowered = Array(name.lowercased())
        }
    }

    // Completions are requested off the main actor, so shared state sits behind a lock.
    private let lock = NSLock()
    private var _text = ""
    private var _candidates: [Candidate] = SQLLanguageService.keywords.map { Candidate(name: $0, kind: "keyword", detail: "keyword") }
    private var schemaCandidates: [Candidate] = []

    var text: String {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }

    func update(tables: [SchemaTable]) {
        var found: [Candidate] = tables.map { Candidate(name: $0.name, kind: $0.isView ? "view" : "table", detail: $0.isView ? "view" : "table") }
        var columnTables: [String: [String]] = [:]
        for table in tables { for column in table.columns { columnTables[column.name, default: []].append(table.name) } }
        for (column, owners) in columnTables.sorted(by: { $0.key < $1.key }) {
            found.append(Candidate(name: column, kind: "column", detail: "column · " + owners.joined(separator: ", ")))
        }
        lock.withLock { schemaCandidates = found }
    }

    // MARK: LanguageService

    private(set) var isOpen = false
    let events = PassthroughSubject<LanguageServiceEvent, Never>()
    let diagnostics = CurrentValueSubject<Set<TextLocated<Message>>, Never>([])
    let completionTriggerCharacters = CurrentValueSubject<[Character], Never>([])
    let extraActions = CurrentValueSubject<[ExtraAction], Never>([])

    func openDocument(with text: String, locationService: LocationService) async throws { isOpen = true }
    func documentDidChange(position changeLocation: Int, changeInLength delta: Int, lineChange deltaLine: Int,
                           columnChange deltaColumn: Int, newText text: String) async throws {}
    func closeDocument() async throws { isOpen = false }
    func tokens(for lineRange: Range<Int>) async throws -> [[(token: LanguageConfiguration.Token, range: NSRange)]] {
        lineRange.map { _ in [] }
    }
    func info(at location: Int) async throws -> (view: any View, anchor: NSRange?)? { nil }
    func capabilities() async throws -> (any View)? { nil }

    func completions(at location: Int, reason: CompletionTriggerReason) async throws -> Completions {
        let source = text as NSString
        guard location <= source.length else { return .none }

        var start = location
        while start > 0, Self.isIdentifierCharacter(source.character(at: start - 1)) { start -= 1 }
        let range = NSRange(location: start, length: location - start)
        let partial = source.substring(with: range)
        guard !partial.isEmpty else { return .none }

        let all = lock.withLock { schemaCandidates } + lock.withLock { _candidates }
        var seen = Set<[Character]>()
        let query = Array(partial.lowercased())
        let ranked = all.compactMap { candidate -> (Candidate, Int)? in
            // Skip exact matches (nothing to complete) and names already listed.
            guard candidate.lowered != query, !seen.contains(candidate.lowered),
                  let score = FuzzyMatch.score(query, inLowercased: candidate.lowered) else { return nil }
            seen.insert(candidate.lowered)
            return (candidate, score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(12)

        let items = ranked.enumerated().map { index, entry -> Completions.Completion in
            let candidate = entry.0
            let insert = Self.insertText(for: candidate)
            return Completions.Completion(
                id: index,
                rowView: { _ in
                    HStack {
                        Text(candidate.name).font(.system(.body, design: .monospaced))
                        Spacer(minLength: 16)
                        Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                    }
                },
                documentationView: Text(candidate.detail),
                selected: index == 0,
                sortText: String(format: "%04d", index),
                filterText: candidate.name,
                insertText: insert,
                insertRange: range,
                commitCharacters: [],
                refine: { nil })
        }
        return Completions(isIncomplete: true, items: items)
    }

    private static func insertText(for candidate: Candidate) -> String {
        if candidate.kind == "keyword" { return candidate.name }
        let plain = candidate.name.unicodeScalars.allSatisfy { isIdentifierCharacter(UInt16($0.value & 0xFFFF)) }
        return plain && !(candidate.name.first?.isNumber ?? false) ? candidate.name : sqlQuote(candidate.name)
    }

    private static func isIdentifierCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static let keywords = """
        ABORT ADD ALL ALTER AND AS ASC AUTOINCREMENT BEGIN BETWEEN BY CASE CAST CHECK COLLATE COMMIT CONFLICT \
        CONSTRAINT COUNT CREATE CROSS DEFAULT DELETE DESC DISTINCT DROP ELSE END ESCAPE EXCEPT EXISTS EXPLAIN \
        FOREIGN FROM FULL GLOB GROUP HAVING IF IN INDEX INNER INSERT INTERSECT INTO IS ISNULL JOIN KEY LEFT LIKE \
        LIMIT MATCH NATURAL NOT NOTNULL NULL OFFSET ON OR ORDER OUTER PRAGMA PRIMARY REFERENCES REINDEX RENAME \
        REPLACE RIGHT ROLLBACK ROW SELECT SET TABLE TEMP THEN TRANSACTION TRIGGER UNION UNIQUE UPDATE USING \
        VACUUM VALUES VIEW WHEN WHERE WITH WITHOUT AVG MAX MIN SUM LENGTH LOWER UPPER SUBSTR COALESCE IFNULL \
        TYPEOF ROUND ABS DATE DATETIME STRFTIME INTEGER TEXT REAL BLOB NUMERIC
        """.split(separator: " ").map(String.init)
}
