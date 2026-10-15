import SwiftUI

/// Structure editor in the spirit of TablePlus. Every change is staged in a draft and shown inline (green new,
/// orange changed, red deleted) until Save applies them together. With no `tableName` it creates a table.
struct TableEditView: View {
    let manager: DatabaseManager
    let tableName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TableDraft()
    @State private var focused: ColumnDraft.ID?
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingDelete = false

    private var isNew: Bool { tableName == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ColumnHeader(onAdd: addColumn)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($draft.columns) { $column in
                        ColumnRow(column: $column, striped: isStriped(column.id), focused: focused == column.id) {
                            remove(column.id)
                        }
                    }
                    // Empty rows below the columns: click the first or double-click any to add a column.
                    // The first also takes double-clicks, so one double-click doesn't add two.
                    ForEach(0..<max(3, 12 - draft.columns.count), id: \.self) { i in
                        FillerRow(striped: (draft.columns.count + i).isMultiple(of: 2) == false, showsHint: i == 0,
                                  onAdd: addColumn)
                            .onTapGesture(count: 2, perform: addColumn)
                            .onTapGesture(count: 1) { if i == 0 { addColumn() } }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 420, idealHeight: 480)
        .onAppear(perform: load)
        .onChange(of: draft) { error = nil }
        .confirmationDialog("Delete “\(tableName ?? "")”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Table", role: .destructive, action: deleteTable)
        } message: {
            Text("The table and every row in it are permanently removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                PlainTextField(text: $draft.name, placeholder: "table_name", focusOnAppear: isNew)
                    .frame(maxWidth: 300)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var subtitle: String {
        guard let table = manager.tables.first(where: { $0.name == tableName }) else { return "New table" }
        return "\(count(draft.live.count, "column")) · \(count(table.indexes.count, "index", "indexes"))"
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Delete Table…", role: .destructive) { confirmingDelete = true }
            }
            if let message = error ?? (draft.hasChanges ? draft.problem : nil) {
                Text(message).foregroundStyle(error == nil ? Color.secondary : Color.red).lineLimit(2).help(message)
            }
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            ShortcutButton("Cancel", role: .cancel, shortcuts: .cancelAction) { dismiss() }
            ShortcutButton(isNew ? "Create Table" : "Save",
                           shortcuts: KeyboardShortcut("s"), KeyboardShortcut(.return, modifiers: .command), action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.hasChanges || draft.problem != nil || saving)
        }
        .padding(12)
    }

    private func load() {
        if let tableName, let table = manager.tables.first(where: { $0.name == tableName }) {
            draft = TableDraft(table)
        }
    }

    private func isStriped(_ id: ColumnDraft.ID) -> Bool {
        (draft.columns.firstIndex { $0.id == id } ?? 0).isMultiple(of: 2) == false
    }

    private func addColumn() {
        let column = ColumnDraft(spec: ColumnSpec(), original: nil)
        draft.columns.append(column)
        focused = column.id
    }

    /// New columns just go; existing ones are marked and can be restored until Save.
    private func remove(_ id: ColumnDraft.ID) {
        guard let index = draft.columns.firstIndex(where: { $0.id == id }) else { return }
        if draft.columns[index].isNew { draft.columns.remove(at: index) } else { draft.columns[index].deleted.toggle() }
    }

    private func save() {
        saving = true
        Task {
            do {
                try await manager.saveStructure(draft)
                if isNew { manager.selection = .table(draft.name.trimmingCharacters(in: .whitespaces)) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func deleteTable() {
        guard let tableName else { return }
        Task {
            do {
                try await manager.deleteTable(tableName)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }
}

/// Fixed widths shared by the header and the rows; the name takes the rest.
private enum Layout {
    static let type: CGFloat = 130
    static let flag: CGFloat = 66
    static let defaultValue: CGFloat = 150
    static let action: CGFloat = 24
    static let rowHeight: CGFloat = 28
    static let spacing: CGFloat = 8
}

private struct ColumnHeader: View {
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: Layout.type, alignment: .leading)
            Text("Primary Key").frame(width: Layout.flag)
            Text("Not Null").frame(width: Layout.flag)
            Text("Unique").frame(width: Layout.flag)
            Text("Default").frame(width: Layout.defaultValue, alignment: .leading)
            ShortcutButton("Add Column", systemImage: "plus", shortcuts: KeyboardShortcut("n"), action: onAdd)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .frame(width: Layout.action)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: Layout.rowHeight)
    }
}

private struct ColumnRow: View {
    @Binding var column: ColumnDraft
    let striped: Bool
    let focused: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Group {
                PlainTextField(text: $column.spec.name, placeholder: "column_name", bordered: false, focusOnAppear: focused)
                    .frame(maxWidth: .infinity)
                ColumnTypePicker(selection: $column.spec.type, custom: column.original?.type)
                    .labelsHidden()
                    .frame(width: Layout.type)
                flag($column.spec.primaryKey)
                flag($column.spec.notNull)
                flag($column.spec.unique)
                PlainTextField(text: $column.spec.defaultValue, placeholder: "None", monospaced: true, bordered: false)
                    .frame(width: Layout.defaultValue)
            }
            .disabled(column.deleted)
            .opacity(column.deleted ? 0.5 : 1)
            Button(column.deleted ? "Restore Column" : "Delete Column",
                   systemImage: column.deleted ? "arrow.uturn.backward" : "minus.circle", action: onRemove)
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                .keyActivated(onRemove)
                .help(column.deleted ? "Restore Column" : "Delete Column")
                .frame(width: Layout.action)
        }
        .padding(.horizontal, 12)
        .frame(height: Layout.rowHeight)
        .background(tint)
        .contextMenu {
            Button(column.deleted ? "Restore Column" : "Delete Column", action: onRemove)
        }
    }

    private func flag(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).labelsHidden().toggleStyle(.checkbox)
            .keyActivated { value.wrappedValue.toggle() }
            .frame(width: Layout.flag)
    }

    private var tint: Color {
        if column.deleted { return .red.opacity(0.16) }
        if column.isNew { return .green.opacity(0.12) }
        if column.isChanged { return .orange.opacity(0.14) }
        return striped ? .primary.opacity(0.04) : .clear
    }
}

private struct FillerRow: View {
    let striped: Bool
    let showsHint: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            if showsHint { Text("Click to add a column").foregroundStyle(.tertiary) }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.rowHeight)
        .background(striped ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .focusable(showsHint)
        .onKeyPress(.space) { onAdd(); return .handled }
        .onKeyPress(.return) { onAdd(); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(showsHint ? "addColumnRow" : "fillerRow")
    }
}

/// The standard SQLite types, plus a column's own declared type when it's something else.
struct ColumnTypePicker: View {
    @Binding var selection: String
    var custom: String?

    var body: some View {
        KeyPopUp(items: options.map { .init(title: $0) }, selected: options.firstIndex(of: selection) ?? 0) {
            selection = options[$0]
        }
    }

    private var options: [String] {
        let standard = ColumnType.allCases.map(\.rawValue)
        let extra = [custom, selection].compactMap { $0 }.filter { !$0.isEmpty && !standard.contains($0) }
        return standard + Array(Set(extra)).sorted()
    }
}
