import SwiftUI
import AppKit

/// Native NSTableView grid (view-based, cell reuse). Sorting and editing report back through closures;
/// sorting is performed by SQL in the database layer, never here.
struct DataGridView: NSViewRepresentable {
    let grid: GridData
    let tableName: String
    let pending: [CellKey: String]
    let editable: Bool
    let sortable: Bool
    let sort: SortState?
    var onSort: (String, Bool) -> Void = { _, _ in }
    var onEdit: (Int, String, String) -> Void = { _, _, _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.rowHeight = 22
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let table = c.tableView else { return }
        let old = c.parent
        c.parent = self

        let structureChanged = c.builtColumns != grid.columns || c.builtTable != tableName || c.builtSortable != sortable
        if structureChanged {
            c.rebuildColumns(table)
            table.reloadData()
        } else if c.builtVersion != grid.version {
            table.reloadData()
        } else if old.pending != pending {
            // Surgical: only the rows whose pending state changed.
            let changed = Set(old.pending.keys).symmetricDifference(pending.keys)
                .union(pending.keys.filter { old.pending[$0] != pending[$0] })
            let ids = Set(changed.map(\.rowID))
            let rows = IndexSet(grid.rowIDs.enumerated().filter { ids.contains($0.element) }.map(\.offset))
            if !rows.isEmpty {
                table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }
        c.builtVersion = grid.version

        let descriptors = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
        if table.sortDescriptors != descriptors {
            c.suppressSort = true
            table.sortDescriptors = descriptors
            c.suppressSort = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DataGridView
        weak var tableView: NSTableView?
        var builtColumns: [String] = []
        var builtTable = ""
        var builtSortable = false
        var builtVersion = -1
        var suppressSort = false
        private let cellID = NSUserInterfaceItemIdentifier("cell")

        init(_ parent: DataGridView) { self.parent = parent }

        func rebuildColumns(_ table: NSTableView) {
            suppressSort = true
            table.tableColumns.forEach(table.removeTableColumn)
            for name in parent.grid.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.title = name
                column.width = CGFloat(min(300, max(100, name.count * 9 + 30)))
                column.minWidth = 40
                column.resizingMask = .userResizingMask
                if parent.sortable {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                }
                table.addTableColumn(column)
            }
            suppressSort = false
            builtColumns = parent.grid.columns
            builtTable = parent.tableName
            builtSortable = parent.sortable
        }

        // MARK: Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { parent.grid.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = parent.grid.columns.firstIndex(of: tableColumn.identifier.rawValue),
                  row < parent.grid.rows.count else { return nil }
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? makeCell()
            let field = cell.textField!
            let (value, isPending) = value(row: row, column: index)
            field.stringValue = value
            field.isEditable = parent.editable && !value.hasPrefix("<blob ")
            field.textColor = isPending ? .systemOrange : (value == "NULL" ? .secondaryLabelColor : .labelColor)
            return cell
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = cellID
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func value(row: Int, column: Int) -> (String, Bool) {
            let name = parent.grid.columns[column]
            if row < parent.grid.rowIDs.count,
               let edited = parent.pending[CellKey(table: parent.tableName, rowID: parent.grid.rowIDs[row], column: name)] {
                return (edited, true)
            }
            return (parent.grid.rows[row][column], false)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressSort, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            parent.onSort(key, first.ascending)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let table = tableView else { return }
            let row = table.row(for: field), column = table.column(for: field)
            guard row >= 0, column >= 0 else { return }
            parent.onEdit(row, table.tableColumns[column].identifier.rawValue, field.stringValue)
            // Re-render this row from state, which also reverts rejected edits.
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }
}
