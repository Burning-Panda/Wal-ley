import Testing
@testable import wal_ley

struct TableDefinitionTests {
    private let sql = """
        CREATE TABLE "my tbl" (
          id INTEGER PRIMARY KEY AUTOINCREMENT, -- the key
          "na,me" varchar(20) NOT NULL DEFAULT 'a,b',
          [price] DECIMAL(10, 2) CHECK (price > 0),
          untyped,
          note TEXT COLLATE NOCASE /* c, ) */,
          UNIQUE (note, price),
          FOREIGN KEY (id) REFERENCES other(id)
        ) STRICT
        """

    @Test func splitsColumnsAndConstraints() throws {
        let definition = try #require(TableDefinition(sql: sql))
        #expect(definition.columnNames == ["id", "na,me", "price", "untyped", "note"])
        #expect(definition.definitions.count == 7)
        #expect(definition.suffix == " STRICT")
    }

    @Test func rewritesTypesAndKeepsEverythingElse() throws {
        var definition = try #require(TableDefinition(sql: sql))
        for (column, type) in [("na,me", "TEXT"), ("price", "REAL"), ("untyped", "BLOB"), ("NOTE", "INTEGER")] {
            #expect(definition.update(column: column) { $0.type = type })
        }
        #expect(!definition.update(column: "missing") { $0.type = "TEXT" })
        definition.insertColumn("\"added\" TEXT UNIQUE")

        // Edited definitions are rebuilt from their tokens, so comments inside them are dropped; untouched ones
        // are kept verbatim.
        #expect(definition.createSQL(name: "tmp") == """
            CREATE TABLE "tmp" (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              "na,me" TEXT NOT NULL DEFAULT 'a,b',
              [price] REAL CHECK (price > 0),
              untyped BLOB,
              note INTEGER COLLATE NOCASE,
              "added" TEXT UNIQUE,
              UNIQUE (note, price),
              FOREIGN KEY (id) REFERENCES other(id)
            ) STRICT
            """)
    }

    @Test func removesOnlyMatchingTableConstraints() throws {
        var definition = try #require(TableDefinition(sql: """
            CREATE TABLE t (a, b, c, CONSTRAINT pk PRIMARY KEY (a, b), UNIQUE (b), UNIQUE ("c"), UNIQUE (b, c))
            """))
        definition.removeTableConstraints(.unique, columns: ["C"])
        #expect(definition.definitions == ["a", "b", "c", "CONSTRAINT pk PRIMARY KEY (a, b)", "UNIQUE (b)", "UNIQUE (b, c)"])
        definition.removeTableConstraints(.primaryKey)
        #expect(definition.definitions == ["a", "b", "c", "UNIQUE (b)", "UNIQUE (b, c)"])
    }

    @Test func columnClausesRoundTrip() throws {
        let clauses = try #require(ColumnClauses(
            #""na,me" varchar(20) CONSTRAINT nn NOT NULL DEFAULT NULL REFERENCES o(id) ON DELETE SET NULL COLLATE NOCASE"#))
        #expect(clauses.unquotedName == "na,me")
        #expect(clauses.type == "varchar(20)")
        #expect(clauses.clauses.map(\.sql) == ["CONSTRAINT nn NOT NULL", "DEFAULT NULL", "REFERENCES o(id) ON DELETE SET NULL", "COLLATE NOCASE"])
        #expect(ColumnClauses("UNIQUE (a, b)") == nil)

        var edited = clauses
        edited.set(.notNull, nil)
        edited.set(.primaryKey, "PRIMARY KEY")
        #expect(edited.sql == #""na,me" varchar(20) PRIMARY KEY DEFAULT NULL REFERENCES o(id) ON DELETE SET NULL COLLATE NOCASE"#)
    }

    @Test func defaultValuesAreQuotedOnlyWhenNeeded() {
        let cases = ["": nil, "abc": "'abc'", "it's": "'it''s'", "42": "42", "-1.5": "-1.5", "null": "null",
                     "CURRENT_TIMESTAMP": "CURRENT_TIMESTAMP", "'x'": "'x'", "(datetime('now'))": "(datetime('now'))"]
        for (typed, sql) in cases {
            #expect(ColumnSpec(defaultValue: typed).defaultSQL == sql, "\(typed)")
        }
    }
}
