import SwiftUI
import CodeEditorView
import LanguageSupport

struct TableDataView: View {
    @Bindable var manager: DatabaseManager

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(manager: manager)
            Divider()
            DataGridView(
                grid: manager.grid,
                tableName: manager.selectedTable?.name ?? "",
                pending: manager.pendingChanges,
                deleted: manager.pendingDeletes,
                editable: manager.isEditable,
                sortable: true,
                sort: manager.sort,
                onSort: { manager.setSort(column: $0, ascending: $1) },
                onEdit: { manager.edit(row: $0, column: $1, newValue: $2) },
                onDelete: { manager.deleteRows($0) },
                onRestore: { manager.restoreRows($0) })
            Divider()
            FooterBar(manager: manager)
        }
    }
}

private struct FilterBar: View {
    @Bindable var manager: DatabaseManager
    @State private var sqlMode = false
    @State private var sqlText = ""
    @State private var position = CodeEditor.Position()
    @State private var messages: Set<TextLocated<Message>> = []
    @State private var column = ""
    @State private var op = FilterOperator.contains
    @State private var value = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KeySegmented(titles: ["Builder", "SQL"], selected: Binding(get: { sqlMode ? 1 : 0 }, set: { sqlMode = $0 == 1 }))
                    .frame(width: 140)
                if sqlMode { sqlButtons } else { builder }
            }
            if sqlMode {
                // The whole query, editable. Paging is applied on top automatically.
                CodeEditor(text: $sqlText, position: $position, messages: $messages, language: .sqlite())
                    .environment(\.codeEditorLayoutConfiguration, CodeEditor.LayoutConfiguration(showMinimap: false, wrapText: true))
                    .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            } else {
                if !manager.filters.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(manager.filters) { filter in
                                Button { manager.removeFilter(filter) } label: {
                                    Label(filter.label, systemImage: "xmark.circle.fill")
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                Text(manager.queryPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .onAppear(perform: resetColumn)
        .onChange(of: manager.selectedTable?.name) { resetColumn(); sqlMode = false; sqlText = "" }
        .onChange(of: sqlMode) { _, isSQL in
            if isSQL {
                // Start from whatever the builder is showing right now.
                sqlText = manager.generatedQuery
            } else if manager.rawQuery != nil {
                manager.setRawQuery(nil)
            }
        }
    }

    @ViewBuilder
    private var builder: some View {
        let names = (manager.selectedTable?.columns ?? []).map(\.name)
        KeyPopUp(items: names.map { .init(title: $0) }, selected: names.firstIndex(of: column) ?? 0) { column = names[$0] }
            .frame(width: 160)
        KeyPopUp(items: FilterOperator.allCases.map { .init(title: $0.rawValue) },
                 selected: FilterOperator.allCases.firstIndex(of: op) ?? 0) { op = FilterOperator.allCases[$0] }
            .frame(width: 150)
        if op.needsValue {
            PlainTextField(text: $value, placeholder: "Value", onSubmit: add)
        }
        let all = manager.selectedTable?.columns ?? []
        KeyPopUp(items: all.map { .init(title: $0.name, checked: manager.isColumnSelected($0.name)) } + [.init(title: "Show All")],
                 title: manager.columnList.map { "Columns \($0.count)/\(all.count)" } ?? "Columns", symbol: "checklist") { index in
            if index < all.count {
                manager.setColumn(all[index].name, selected: !manager.isColumnSelected(all[index].name))
            } else {
                manager.showAllColumns()
            }
        }
        .fixedSize()
        ShortcutButton("Add Filter", systemImage: "line.3.horizontal.decrease",
                       shortcuts: KeyboardShortcut(.return, modifiers: .command), action: add)
            .disabled(column.isEmpty || (op.needsValue && value.isEmpty))
        if !op.needsValue { Spacer() }
    }

    @ViewBuilder
    private var sqlButtons: some View {
        ShortcutButton("Run", systemImage: "play.fill", shortcuts: KeyboardShortcut(.return, modifiers: .command)) {
            manager.setRawQuery(sqlText)
        }
        Button("Reset") { manager.setRawQuery(nil); sqlText = manager.generatedQuery }
            .keyActivated { manager.setRawQuery(nil); sqlText = manager.generatedQuery }
        Text("Read-only · paging and header sorting apply on top")
            .font(.caption).foregroundStyle(.secondary)
        Spacer()
    }

    private func resetColumn() { column = manager.selectedTable?.columns.first?.name ?? "" }

    private func add() {
        guard !column.isEmpty, !op.needsValue || !value.isEmpty else { return }
        manager.addFilter(ColumnFilter(column: column, op: op, value: op.needsValue ? value : ""))
        value = ""
    }
}

private struct FooterBar: View {
    @Bindable var manager: DatabaseManager
    @State private var showingSQL = false

    var body: some View {
        HStack {
            // ⌘[ and ⌘] are the standard Back and Forward.
            ShortcutButton("Previous", systemImage: "chevron.left", shortcuts: KeyboardShortcut("[")) {
                manager.goToPage(manager.page - 1)
            }
                .disabled(manager.page == 0)
            ShortcutButton("Next", systemImage: "chevron.right", shortcuts: KeyboardShortcut("]")) {
                manager.goToPage(manager.page + 1)
            }
                .disabled(manager.page >= manager.pageCount - 1)
            Text(rangeText).foregroundStyle(.secondary)
            if manager.isLoading { ProgressView().controlSize(.small) }
            if !manager.isEditable && manager.selectedTable != nil {
                Label("Read-only", systemImage: "lock").foregroundStyle(.secondary)
            }
            if let error = manager.errorMessage {
                Text(error).foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            if manager.pendingCount > 0 {
                Text("\(manager.pendingCount) unsaved").foregroundStyle(.orange)
                ShortcutButton("View SQL", systemImage: "text.alignleft", help: "Show the SQL that Save will run",
                               shortcuts: KeyboardShortcut("l")) { showingSQL = true }
                    .labelStyle(.titleAndIcon)
                ShortcutButton("Discard", shortcuts: KeyboardShortcut("d")) { manager.discardChanges() }
                ShortcutButton("Save", shortcuts: KeyboardShortcut("s")) { Task { await manager.saveChanges() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .labelStyle(.iconOnly)
        .font(.caption)
        .padding(8)
        .sheet(isPresented: $showingSQL) { PendingSQLSheet(sql: manager.pendingSQL) }
    }

    private var rangeText: String {
        let size = DatabaseManager.pageSize
        let start = manager.totalRows == 0 ? 0 : manager.page * size + 1
        let end = min(manager.totalRows, (manager.page + 1) * size)
        return "\(start)–\(end) of \(manager.totalRows)"
    }
}

/// The pending changes as the SQL Save will run, for review before committing.
private struct PendingSQLSheet: View {
    let sql: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SQL to run on Save").font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(sql)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
                Spacer()
                ShortcutButton("Done", shortcuts: .cancelAction, .defaultAction) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 280)
    }
}
