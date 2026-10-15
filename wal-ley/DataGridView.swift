import SwiftUI
import AppKit

/// Native NSTableView grid (view-based, cell reuse). Sorting, editing and deleting report back through
/// closures; sorting is performed by SQL in the database layer, never here.
struct DataGridView: NSViewRepresentable {
    let grid: GridData
    let tableName: String
    let pending: [CellKey: String]
    var deleted: Set<RowKey> = []
    let editable: Bool
    let sortable: Bool
    let sort: SortState?
    var onSort: (String, Bool) -> Void = { _, _ in }
    var onEdit: (Int, String, String) -> Void = { _, _, _ in }
    var onDelete: (IndexSet) -> Void = { _ in }
    var onRestore: (IndexSet) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.rowHeight = 22
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onDeleteKey = { [weak coordinator = context.coordinator] in coordinator?.deleteSelection() }
        table.onReturnKey = { [weak coordinator = context.coordinator] in coordinator?.editFocusedCell() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
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
        } else if old.pending != pending || old.deleted != deleted {
            // Surgical: only the rows whose pending state changed.
            var ids = Set(Set(old.pending.keys).symmetricDifference(pending.keys).map(\.rowID))
            ids.formUnion(pending.keys.filter { old.pending[$0] != pending[$0] }.map(\.rowID))
            ids.formUnion(old.deleted.symmetricDifference(deleted).map(\.rowID))
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

    /// Report the proposed size instead of letting SwiftUI measure the NSScrollView. Measuring forces AppKit to lay out
    /// the whole table (creating every visible cell) on each SwiftUI layout pass, e.g. when the filter bar changes height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Forwards Delete / Forward Delete to the grid instead of beeping. Up and down move the selected row as usual;
    /// left and right move the focused cell along it, and return edits that cell.
    final class GridTableView: NSTableView {
        var onDeleteKey: () -> Void = {}
        var onReturnKey: () -> Void = {}
        /// The cell the keyboard is on, within the selected row; outlined while the grid has focus.
        var activeColumn = -1 { didSet { redrawRows() } }

        /// Row views draw the selection and the outline, so they need telling, not the table.
        private func redrawRows() {
            enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
        }

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            switch event.keyCode {
            case 51, 117: onDeleteKey()
            case 36, 76 where plain: onReturnKey()
            case 123 where plain: moveFocus(by: -1)
            case 124 where plain: moveFocus(by: 1)
            default: super.keyDown(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let column = column(at: convert(event.locationInWindow, from: nil))
            super.mouseDown(with: event)
            if column >= 0 { activeColumn = column }
        }

        override func becomeFirstResponder() -> Bool {
            if activeColumn < 0, numberOfColumns > 0 { activeColumn = 0 }
            if selectedRow < 0, numberOfRows > 0 { selectRowIndexes([0], byExtendingSelection: false) }
            let became = super.becomeFirstResponder()
            redrawRows()
            return became
        }

        private func moveFocus(by step: Int) {
            guard numberOfColumns > 0 else { return }
            let next = min(max(activeColumn + step, 0), numberOfColumns - 1)
            activeColumn = next
            if selectedRow >= 0 { scrollColumnToVisible(next) }
        }

        override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
            super.selectRowIndexes(indexes, byExtendingSelection: extend)
            redrawRows()
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            redrawRows()
            return resigned
        }
    }

    /// Selected rows draw their highlight in the row view, over the table's own drawing, so the active cell's
    /// outline is drawn here as well, on top of the highlight.
    final class GridRowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            super.drawSelection(in: dirtyRect)
            guard let table = superview as? GridTableView, table.window?.firstResponder === table,
                  table.activeColumn >= 0, table.activeColumn < table.numberOfColumns else { return }
            let row = table.row(for: self)
            guard row >= 0 else { return }
            let frame = convert(table.frameOfCell(atColumn: table.activeColumn, row: row), from: table).insetBy(dx: 1, dy: 1)
            NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            path.lineWidth = 2
            NSColor.alternateSelectedControlTextColor.setStroke()
            path.stroke()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: DataGridView
        weak var tableView: GridTableView?
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

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GridRowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = parent.grid.columns.firstIndex(of: tableColumn.identifier.rawValue),
                  row < parent.grid.rows.count else { return nil }
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? makeCell()
            let field = cell.textField!
            let (value, isPending) = value(row: row, column: index)
            let isDeleted = isDeleted(row: row)
            // Fields are only editable while a double-click edit is in progress.
            field.isEditable = false
            if isDeleted {
                field.attributedStringValue = NSAttributedString(string: value, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 12),
                ])
            } else {
                field.stringValue = value
                field.textColor = isPending ? .systemOrange : (value == "NULL" ? .secondaryLabelColor : .labelColor)
            }
            return cell
        }

        /// Cells use autoresizing, not Auto Layout: constraints for every visible cell are what made big grids slow.
        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
            cell.identifier = cellID
            let field = NSTextField(frame: NSRect(x: 4, y: 2.5, width: 112, height: 17))
            field.autoresizingMask = [.width]
            field.isBordered = false
            field.drawsBackground = false
            field.isSelectable = false
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.delegate = self
            cell.addSubview(field)
            cell.textField = field
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

        private func isDeleted(row: Int) -> Bool {
            row < parent.grid.rowIDs.count
                && parent.deleted.contains(RowKey(table: parent.tableName, rowID: parent.grid.rowIDs[row]))
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !suppressSort, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            parent.onSort(key, first.ascending)
        }

        // MARK: Editing (double-click)

        @objc func doubleClicked(_ sender: NSTableView) {
            beginEdit(in: sender, row: sender.clickedRow, column: sender.clickedColumn)
        }

        /// Return on the selected row edits its focused cell.
        func editFocusedCell() {
            guard let table = tableView, table.selectedRowIndexes.count == 1 else { return }
            beginEdit(in: table, row: table.selectedRow, column: table.activeColumn)
        }

        private func beginEdit(in sender: NSTableView, row: Int, column: Int) {
            guard parent.editable, row >= 0, column >= 0, !isDeleted(row: row),
                  let cell = sender.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField, !field.stringValue.hasPrefix("<blob ") else { return }
            field.isEditable = true
            field.isSelectable = true
            // Deferred: the table is still finishing the click that fired this action and would
            // take first responder back from the field.
            DispatchQueue.main.async { [weak sender, weak field] in
                guard let sender, let field else { return }
                sender.editColumn(column, row: row, with: nil, select: true)
                if field.currentEditor() == nil {
                    sender.window?.makeFirstResponder(field)
                    field.selectText(nil)
                }
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let table = tableView else { return }
            field.isEditable = false
            field.isSelectable = false
            let row = table.row(for: field), column = table.column(for: field)
            guard row >= 0, column >= 0 else { return }
            parent.onEdit(row, table.tableColumns[column].identifier.rawValue, field.stringValue)
            // Re-render this row from state, which also reverts rejected edits.
            table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }

        // MARK: Deleting / context menu

        func deleteSelection() {
            guard let table = tableView, parent.editable, !table.selectedRowIndexes.isEmpty else { return }
            parent.onDelete(table.selectedRowIndexes)
        }

        @objc private func restoreSelection() {
            if let table = tableView { parent.onRestore(table.selectedRowIndexes) }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = tableView, parent.editable else { return }
            // Right-click on an unselected row acts on that row, as in Finder.
            if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            }
            let count = table.selectedRowIndexes.count
            guard count > 0 else { return }
            let noun = count == 1 ? "Row" : "\(count) Rows"
            let delete = NSMenuItem(title: "Delete \(noun)", action: #selector(deleteFromMenu), keyEquivalent: "")
            let restore = NSMenuItem(title: "Restore \(noun)", action: #selector(restoreSelection), keyEquivalent: "")
            [delete, restore].forEach { $0.target = self; menu.addItem($0) }
        }

        @objc private func deleteFromMenu() { deleteSelection() }
    }
}
