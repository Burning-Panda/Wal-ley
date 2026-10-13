import SwiftUI

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
                editable: manager.isEditable,
                sortable: true,
                sort: manager.sort,
                onSort: { manager.setSort(column: $0, ascending: $1) },
                onEdit: { manager.edit(row: $0, column: $1, newValue: $2) })
            Divider()
            FooterBar(manager: manager)
        }
    }
}

private struct FilterBar: View {
    @Bindable var manager: DatabaseManager
    @State private var column = ""
    @State private var op = FilterOperator.contains
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Column", selection: $column) {
                    ForEach(manager.selectedTable?.columns ?? []) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().frame(width: 160)
                Picker("Operator", selection: $op) {
                    ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                if op.needsValue {
                    TextField("Value", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                }
                Button("Add Filter", systemImage: "line.3.horizontal.decrease", action: add)
                    .disabled(column.isEmpty || (op.needsValue && value.isEmpty))
                if !op.needsValue { Spacer() }
            }
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
        }
        .padding(8)
        .onAppear(perform: resetColumn)
        .onChange(of: manager.selectedTable?.name) { resetColumn() }
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
            Button("Previous", systemImage: "chevron.left") { manager.goToPage(manager.page - 1) }
                .disabled(manager.page == 0)
            Button("Next", systemImage: "chevron.right") { manager.goToPage(manager.page + 1) }
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
            if !manager.pendingChanges.isEmpty {
                Text("\(manager.pendingChanges.count) unsaved").foregroundStyle(.orange)
                Button("Discard") { manager.discardChanges() }
                Button("Save") { Task { await manager.saveChanges() } }
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
