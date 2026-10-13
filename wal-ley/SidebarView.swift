import SwiftUI

struct SidebarView: View {
    @Bindable var manager: DatabaseManager
    @State private var search = ""

    var body: some View {
        List(selection: $manager.selection) {
            Label("SQL Console", systemImage: "terminal")
                .tag(SidebarItem.console)
            section("Tables", visible.filter { !$0.isView })
            section("Views", visible.filter { $0.isView })
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter tables")
        .safeAreaInset(edge: .bottom) {
            if let metadata = manager.metadata { MetadataView(metadata: metadata, readOnly: manager.isReadOnly) }
        }
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
    private func section(_ title: String, _ items: [SchemaTable]) -> some View {
        if !items.isEmpty {
            Section(title) {
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
