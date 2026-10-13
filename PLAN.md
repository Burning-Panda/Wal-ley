# wal-ley: SQLite reader/editor (macOS, SwiftUI + AppKit grid)

## Stack
- GRDB for SQLite, CodeEditorView for the SQL console, both via SPM. Sandbox off so `-wal`/`-shm` files are reachable.

## Layout
- `DatabaseManager` (`@MainActor @Observable`): connection, schema, selection, paging/sort/filter state, pending edits, console state. Heavy work is `async` on the GRDB queue.
- `DataGridView`: `NSTableView` in an `NSViewRepresentable`; view-based cell reuse; `NSTextField` delegate for inline edits; surgical row reloads.
- `SidebarView`: SQL Console entry, fuzzy-filtered tables/views (columns + indexes), file metadata.
- `TableDataView`: filter bar, grid, paging/save footer. `ConsoleView`: CodeEditorView + results grid.
- `SQLLanguageService`: fuzzy autocomplete for keywords, tables, columns.

## Rules
- Sorting, filtering and paging are SQL (`ORDER BY`, parameterised `WHERE`, `LIMIT/OFFSET`); never in the view layer.
- Edits are tracked in `pendingChanges` and written in one transaction on Save.
- Console is its own mode: selecting it clears table data and table selection.
- Release: pushing a `v*` tag builds an unsigned zip via GitHub Actions.
