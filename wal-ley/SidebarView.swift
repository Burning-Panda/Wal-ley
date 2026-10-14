import SwiftUI

struct SidebarView: View {
    @Bindable var manager: DatabaseManager
    @State private var search = ""
    @State private var editingTable: SchemaTable?
    @State private var deletingTable: SchemaTable?
    @State private var schemaError: String?

    private var canEditSchema: Bool { manager.isOpen && !manager.isReadOnly }

    var body: some View {
        List(selection: $manager.selection) {
            Label("SQL Console", systemImage: "terminal")
                .tag(SidebarItem.console)
            section("Tables", visible.filter { !$0.isView }, canAdd: canEditSchema)
            section("Views", visible.filter { $0.isView })
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in menu(for: items) }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter tables")
        .safeAreaInset(edge: .bottom) {
            if let metadata = manager.metadata { MetadataView(metadata: metadata, readOnly: manager.isReadOnly) }
        }
        .sheet(isPresented: $manager.showNewTable) {
            TableEditView(manager: manager, tableName: nil)
        }
        .sheet(item: $editingTable) { table in
            TableEditView(manager: manager, tableName: table.name)
        }
        .confirmationDialog("Delete “\(deletingTable?.name ?? "")”?", isPresented: deletingBinding,
                            titleVisibility: .visible, presenting: deletingTable) { table in
            Button(table.isView ? "Delete View" : "Delete Table", role: .destructive) { delete(table) }
        } message: { table in
            Text(table.isView ? "The view's definition is removed; its underlying tables are not touched."
                              : "The table and every row in it are permanently removed.")
        }
        .alert("Couldn't change the schema", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(schemaError ?? "")
        }
    }

    @ViewBuilder
    private func menu(for items: Set<SidebarItem>) -> some View {
        if canEditSchema {
            if items.count == 1, case .table(let name)? = items.first,
               let table = manager.tables.first(where: { $0.name == name }) {
                if !table.isView {
                    Button("Edit Table…") { afterUnsaved { editingTable = table } }
                }
                Button(table.isView ? "Delete View…" : "Delete Table…", role: .destructive) {
                    afterUnsaved { deletingTable = table }
                }
            } else if items.isEmpty {
                Button("New Table…") { manager.showNewTable = true }
            }
        }
    }

    /// Schema changes reset the open table, so unsaved edits are dealt with first.
    private func afterUnsaved(_ action: @escaping () -> Void) {
        Task { await manager.guardUnsaved { action() } }
    }

    private func delete(_ table: SchemaTable) {
        Task {
            do { try await manager.deleteTable(table.name) } catch { schemaError = error.localizedDescription }
        }
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deletingTable != nil }, set: { if !$0 { deletingTable = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { schemaError != nil }, set: { if !$0 { schemaError = nil } })
    }

    /// Fuzzy-filtered, best match first while searching.
    private var visible: [SchemaTable] {
        guard !search.isEmpty else { return manager.tables }
        return manager.tables
            .compactMap { table in FuzzyMatch.score(search, in: table.name).map { (table, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SchemaTable], canAdd: Bool = false) -> some View {
        if !items.isEmpty || canAdd {
            Section {
                ForEach(items) { table in
                    DisclosureGroup {
                        ForEach(table.columns) { column in
                            HStack {
                                Text(column.name)
                                Spacer()
                                Text(definition(column)).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        ForEach(table.indexes) { index in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(index.name + (index.unique ? " (unique)" : ""))
                                    Text(index.columns.joined(separator: ", ")).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "list.number")
                            }
                            .font(.callout)
                        }
                    } label: {
                        Label(table.name, systemImage: table.isView ? "eye" : "tablecells")
                    }
                    .tag(SidebarItem.table(table.name))
                }
            } header: {
                HStack {
                    Text(title)
                    Spacer()
                    if canAdd {
                        ShortcutButton("New Table", systemImage: "plus", shortcuts: KeyboardShortcut("n", modifiers: [.command, .shift])) {
                            manager.showNewTable = true
                        }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            // Line up with the trailing edge of the selected row's content.
                            .padding(.trailing, 10)
                    }
                }
            }
        }
    }

    private func definition(_ column: SchemaColumn) -> String {
        [column.type.isEmpty ? nil : column.type, column.primaryKey ? "PK" : nil, column.notNull ? "NOT NULL" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}

private struct MetadataView: View {
    let metadata: FileMetadata
    let readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(metadata.name + (readOnly ? " (read-only)" : ""), systemImage: "doc")
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(metadata.directory)
                .lineLimit(1).truncationMode(.middle)
                .help(metadata.directory)
            Text(ByteCountFormatter.string(fromByteCount: metadata.size, countStyle: .file))
            if let modified = metadata.modified {
                Text(modified.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}
