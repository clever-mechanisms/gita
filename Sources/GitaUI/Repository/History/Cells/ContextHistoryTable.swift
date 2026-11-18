import AppKit

/// The history table: a secondary click selects the row under it before its menu opens, so the menu acts on it.
@MainActor
final class ContextHistoryTable: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return super.menu(for: event)
    }
}
