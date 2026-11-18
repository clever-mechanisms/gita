import AppKit
import GitaCore

/// The commit table: one row per commit in replay order, reordered with Up/Down or by dragging.
extension InteractiveRebaseController {
    func buildTable() {
        for (column, title, width) in [
            (Column.action, String(localized: "Action"), CGFloat(110)),
            (Column.subject, String(localized: "Subject"), CGFloat(470)),
            (Column.sha, String(localized: "Commit"), CGFloat(80)),
        ] {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            if column == .subject {
                tableColumn.minWidth = 180
                tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                tableColumn.minWidth = width
                tableColumn.maxWidth = width
                tableColumn.resizingMask = []
            }
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel(String(localized: "Rebase commits in replay order"))
        table.setAccessibilityIdentifier("rebase.commits")
        let scroll = Style.scroll(table)
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        Style.fill(scroll, in: tableContainer)
        tableContainer.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor, constant: 10),
        ])
    }

    func numberOfRows(in _: NSTableView) -> Int { plan.steps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard plan.steps.indices.contains(row), let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        let step = plan.steps[row]
        guard column != .action else { return actionCell(step, in: tableView, identifier: tableColumn.identifier) }
        let cell =
            tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? RebaseCommitCell
            ?? RebaseCommitCell()
        cell.identifier = tableColumn.identifier
        let isSHA = column == .sha
        let value = isSHA ? String(step.commitID.prefix(10)) : plan.commits[step.commitID]?.subject ?? ""
        cell.update(value, monospaced: isSHA, dropped: step.action == .drop)
        cell.textField?.setAccessibilityIdentifier("rebase." + column.rawValue)
        cell.toolTip = isSHA ? step.commitID : value
        return cell
    }
    private func actionCell(
        _ step: GitRebaseStep, in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier
    ) -> NSView {
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? RebaseActionCell ?? RebaseActionCell()
        cell.identifier = identifier
        cell.picker.commitID = step.commitID
        cell.picker.target = self
        cell.picker.action = #selector(actionChanged(_:))
        cell.picker.selectItem(at: GitRebaseAction.allCases.firstIndex(of: step.action) ?? 0)
        cell.picker.isEnabled = canEdit
        cell.picker.contentTintColor = step.action == .drop ? .systemRed : nil
        cell.picker.setAccessibilityLabel(String(localized: "Action for commit \(step.commitID.prefix(12))"))
        return cell
    }
    /// The pickers already on screen follow whether the plan can be edited.
    func updateVisiblePickers() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<min(plan.steps.count, NSMaxRange(visible)) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RebaseActionCell)?.picker.isEnabled =
                canEdit
        }
    }
    func selectionShouldChange(in _: NSTableView) -> Bool { restoringSelection || canEdit }
    func tableViewSelectionDidChange(_: Notification) {
        guard !restoringSelection else { return }
        saveEditorPosition()
        selectedID = plan.steps.indices.contains(table.selectedRow) ? plan.steps[table.selectedRow].commitID : nil
        inputError = nil
        showSelectedEditor()
        updateControls()
    }
    func reloadTable(scrollToSelection: Bool) {
        restoringSelection = true
        table.reloadData()
        if let row = selectedIndex {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scrollToSelection { table.scrollRowToVisible(row) }
        } else {
            table.deselectAll(nil)
        }
        restoringSelection = false
    }
    @objc func actionChanged(_ sender: RebaseActionPicker) {
        guard canEdit, let id = sender.commitID,
            GitRebaseAction.allCases.indices.contains(sender.indexOfSelectedItem),
            plan.setAction(GitRebaseAction.allCases[sender.indexOfSelectedItem], for: id)
        else { return }
        saveEditorPosition()
        selectedID = id
        inputError = nil
        reloadTable(scrollToSelection: false)
        showSelectedEditor()
        updateControls()
    }
    func move(from source: Int, to destination: Int) {
        guard canEdit else { return }
        saveEditorPosition()
        guard plan.move(from: source, to: destination) else { return }
        selectedID = plan.steps[destination].commitID
        reloadTable(scrollToSelection: true)
        showSelectedEditor()
        updateControls()
    }
    @objc func moveCommitEarlier() { if let row = selectedIndex { move(from: row, to: row - 1) } }
    @objc func moveCommitLater() { if let row = selectedIndex { move(from: row, to: row + 1) } }

    // MARK: Dragging

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard canEdit, plan.steps.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(dragIdentity + ":" + plan.steps[row].commitID, forType: Self.dragType)
        return item
    }
    /// The dragged row, only for a drag from this sheet's own table.
    func draggedRow(_ info: any NSDraggingInfo) -> Int? {
        guard info.draggingSource as? NSTableView === table,
            let value = info.draggingPasteboard.string(forType: Self.dragType)
        else { return nil }
        return draggedRow(payload: value)
    }
    func draggedRow(payload value: String) -> Int? {
        guard value.hasPrefix(dragIdentity + ":") else { return nil }
        return plan.index(of: String(value.dropFirst(dragIdentity.count + 1)))
    }
    func tableView(
        _: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard canEdit, operation == .above, (0...plan.steps.count).contains(row), draggedRow(info) != nil else {
            return []
        }
        return .move
    }
    func tableView(
        _: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        guard canEdit, operation == .above, let source = draggedRow(info) else { return false }
        return drop(from: source, above: row)
    }
    /// Moves the row dropped above `row`; false when that is no move.
    func drop(from source: Int, above row: Int) -> Bool {
        guard (0...plan.steps.count).contains(row) else { return false }
        let destination = row > source ? row - 1 : row
        guard plan.steps.indices.contains(destination) else { return false }
        move(from: source, to: destination)
        return true
    }
}
