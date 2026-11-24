import AppKit
import GitaCore

/// Split-view cell configuration and layout switching for `DiffView`.
extension DiffView {
    func applyLayoutChange() {
        table.reloadData()
        updateColumnWidth()
        updateHunkBarInsets()
        updateSelectionBar()
    }

    func splitViewForRow(_ tableView: NSTableView, row: Int) -> NSView? {
        guard splitRows.indices.contains(row) else { return nil }
        let split = splitRows[row]
        if split.isHunkHeader, let line = split.left ?? split.right {
            let bar = tableView.makeView(withIdentifier: Self.hunkBarID, owner: nil) as? DiffHunkBar ?? DiffHunkBar()
            bar.identifier = Self.hunkBarID
            configureHunkBar(bar, line: line)
            return bar
        }
        let cell = tableView.makeView(withIdentifier: Self.splitCellID, owner: nil) as? DiffSplitCell ?? DiffSplitCell()
        cell.identifier = Self.splitCellID
        configureSplitCell(cell, split: split, selectedDocRows: selectedStageableDocumentRows)
        return cell
    }

    func configureSplitView(rowView: NSTableRowView, row: Int, selectedDocRows: IndexSet) {
        let split = splitRows[row]
        if let cell = rowView.view(atColumn: 0) as? DiffSplitCell {
            configureSplitCell(cell, split: split, selectedDocRows: selectedDocRows)
        } else if let bar = rowView.view(atColumn: 0) as? DiffHunkBar, let line = split.left ?? split.right {
            configureHunkBar(bar, line: line)
        }
    }

    private func configureSplitCell(_ cell: DiffSplitCell, split: SplitDiffRow, selectedDocRows: IndexSet) {
        cell.fontSize = fontSize
        cell.tabWidth = tabWidth
        cell.row = split
        cell.leftFind = split.leftRowIndex.map { findHighlight(for: $0) } ?? ([], nil)
        cell.rightFind = split.rightRowIndex.map { findHighlight(for: $0) } ?? ([], nil)
        cell.isStageSelectionMarked = split.stageableDocumentRows.contains { selectedDocRows.contains($0) }
        if let line = split.right ?? split.left {
            cell.customActions = customActions(for: line)
        } else {
            cell.customActions = []
        }
    }

    func scrollToDocumentRow(_ docRow: Int) {
        if activeLayout == .split {
            if let splitIndex = splitRows.firstIndex(where: { $0.leftRowIndex == docRow || $0.rightRowIndex == docRow })
            {
                table.scrollRowToVisible(splitIndex)
            }
            return
        }
        table.scrollRowToVisible(docRow)
    }
}
