import AppKit

/// The outline's context menu acts on the clicked row (added to the selection unless it is already part of it), Return
/// activates, and a click reports focus.
@MainActor
final class FileOutline: NSOutlineView {
    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
    }
    var rowMenu: ((IndexSet) -> NSMenu?)?
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onFocus: (() -> Void)?
    /// The row of the last click, until a key moves the selection (`clickedRow` keeps the old click meanwhile).
    private(set) var mouseRow: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        onFocus?()
        return rowMenu?(selectedRowIndexes)
    }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        let row = row(at: convert(event.locationInWindow, from: nil))
        mouseRow = row >= 0 ? row : nil
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        mouseRow = nil
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter {
            onReturn?()
            return
        }
        if KeyPress.isPlain(event), event.keyCode == KeyPress.space, let onSpace {
            onSpace()
            return
        }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}
