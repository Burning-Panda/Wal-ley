# wal-ley: SQLite reader/editor (macOS, SwiftUI + AppKit grid)

## Stack
- GRDB for SQLite, CodeEditorView for the SQL console, both via SPM. Sandbox off so `-wal`/`-shm` files are reachable.

## Layout
- `DatabaseManager` (`@MainActor @Observable`): connection, schema, selection, paging/sort/filter state, pending edits, console state. Heavy work is `async` on the GRDB queue.
- `DataGridView`: `NSTableView` in an `NSViewRepresentable`; view-based cell reuse; `NSTextField` delegate for inline edits; surgical row reloads.
- `SidebarView`: SQL Console entry, fuzzy-filtered tables/views (columns + indexes), file metadata.
- `TableDataView`: filter bar, grid, paging/save footer. `ConsoleView`: CodeEditorView + results grid.
- `SQLLanguageService`: fuzzy autocomplete for keywords, tables, columns.
- Schema editing: `TableEditView` is a staged structure editor (sidebar `+`, or right-click a table). Edits live in a `TableDraft` until Save, which applies them in one transaction: drops/renames/plain adds via `ALTER TABLE`, everything else via one table rebuild. `TableDefinition`/`ColumnClauses` rewrite the stored CREATE TABLE so CHECKs, collations and FKs survive.

## Rules
- Shortcuts follow the macOS standard: ⌘S save, ⌘N new database (new column inside the structure editor), ⌘T new table, ⌘O open, ⌘[ / ⌘] back/forward (pages), esc cancel; ⌘↩ is each view's main action. Buttons with shortcuts use `ShortcutButton`, which shows the keys and underlines the letter while ⌘ is held. A view's own shortcut wins over a menu item with the same keys, so menus hold the app-wide fallback.
- Sorting, filtering and paging are SQL (`ORDER BY`, parameterised `WHERE`, `LIMIT/OFFSET`); never in the view layer.
- Edits are tracked in `pendingChanges` and written in one transaction on Save.
- Console is its own mode: selecting it clears table data and table selection.
- Release: pushing a `v*` tag builds an unsigned zip via GitHub Actions.

## Tests
- `wal-leyTests`: schema editing against real database files, the CREATE TABLE rewriter, shortcut symbols/tooltips/underlines.
- `wal-leyUITests`: drive the real app (shortcuts, ⌘ hints, structure editor clicks, one window). They launch with `-open <path>` (the app opens that database at launch) and `-ApplePersistenceIgnoreState YES`, and read results back with `/usr/bin/sqlite3`. Tooltips can't be read by XCUITest; `testToolbarTooltipScreenshots` attaches hover screenshots to the report instead.
- The app is one window over one `DatabaseManager`; `SingleWindow` closes any extra window macOS restores.
