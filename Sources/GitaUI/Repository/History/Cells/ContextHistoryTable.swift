import AppKit
import GitaCore

/// The history table: a secondary click selects the row under it before its menu opens, so the menu acts on it. On
/// a reference pill the menu is that reference's (`referenceMenu`), else the table's own (the commit's).
@MainActor
final class ContextHistoryTable: NSTableView {
    /// The menu for the pill of `reference` on the commit with this ID; nil falls back to the commit's menu.
    var referenceMenu: ((_ commitID: String, _ reference: ReferenceBadge) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return pillMenu(at: point, row: index) ?? super.menu(for: event)
    }

    private func pillMenu(at point: NSPoint, row index: Int) -> NSMenu? {
        let columnIndex = column(at: point)
        guard columnIndex >= 0,
            let cell = view(atColumn: columnIndex, row: index, makeIfNecessary: false) as? HistoryCommitCell,
            let reference = cell.reference(at: cell.convert(point, from: self))
        else { return nil }
        return referenceMenu?(cell.representedCommitID, reference)
    }
}
