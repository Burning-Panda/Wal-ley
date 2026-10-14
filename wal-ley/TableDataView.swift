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
                Picker("Mode", selection: $sqlMode) {
                    Text("Builder").tag(false)
                    Text("SQL").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
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
        Picker("Column", selection: $column) {
            ForEach(manager.selectedTable?.columns ?? []) { Text($0.name).tag($0.name) }
        }
        .labelsHidden().frame(width: 160)
        Picker("Operator", selection: $op) {
            ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().frame(width: 150)
        if op.needsValue {
            PlainTextField(text: $value, placeholder: "Value", onSubmit: add)
        }
        Menu {
            ForEach(manager.selectedTable?.columns ?? []) { col in
                Toggle(col.name, isOn: Binding(
                    get: { manager.isColumnSelected(col.name) },
                    set: { manager.setColumn(col.name, selected: $0) }))
            }
            Divider()
            Button("Show All") { manager.showAllColumns() }
        } label: {
            let total = manager.selectedTable?.columns.count ?? 0
            Label(manager.columnList.map { "Columns \($0.count)/\(total)" } ?? "Columns", systemImage: "checklist")
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
                Button("Discard") { manager.discardChanges() }
                ShortcutButton("Save", shortcuts: KeyboardShortcut("s")) { Task { await manager.saveChanges() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .labelStyle(.iconOnly)
        .font(.caption)
        .padding(8)
    }

    private var rangeText: String {
        let size = DatabaseManager.pageSize
        let start = manager.totalRows == 0 ? 0 : manager.page * size + 1
        let end = min(manager.totalRows, (manager.page + 1) * size)
        return "\(start)–\(end) of \(manager.totalRows)"
    }
}
