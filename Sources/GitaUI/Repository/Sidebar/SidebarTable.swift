import AppKit

/// The sidebar's list: a menu per row, Return opens the selected row, Left, Right and Space close, open and toggle a
/// selected group, and the header's sort button takes its clicks.
@MainActor
final class SidebarTable: NSTableView {
    /// What a key does to the selected group.
    enum GroupChange {
        case close, open, toggle
    }

    private static let returnKeys: Set<UInt16> = [KeyPress.returnKey, KeyPress.keypadEnter]
    private static let groupKeys: [UInt16: GroupChange] = [
        KeyPress.leftArrow: .close, KeyPress.rightArrow: .open, KeyPress.space: .toggle,
    ]

    var rowMenu: ((Int) -> NSMenu?)?
    var onReturn: (() -> Void)?
    /// Plain Spacebar on a non-group row (e.g. a Stash row for Quick Look).
    var onSpace: (() -> Bool)?
    /// Changes the selected group; false when the selected row is not one (the table then handles the key).
    var onExpand: ((GroupChange) -> Bool)?
    /// Clicking directly on a row's disclosure chevron toggles expansion without selecting or navigating.
    var onChevronClick: ((Int) -> Void)?
    /// Modifier flags captured from the latest mouse down event on this table.
    private(set) var lastClickModifiers: NSEvent.ModifierFlags?

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, index < numberOfRows else { return nil }
        return rowMenu?(index)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hitRow = row(at: point)
        if hitRow >= 0, hitRow < numberOfRows,
            let cell = view(atColumn: 0, row: hitRow, makeIfNecessary: false) as? SidebarCell,
            cell.isChevronHit(at: cell.convert(point, from: self))
        {
            lastClickModifiers = nil
            onChevronClick?(hitRow)
            return
        }
        lastClickModifiers = event.modifierFlags
        defer { lastClickModifiers = nil }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.returnKeys.contains(event.keyCode) {
            onReturn?()
            return
        }
        if let change = Self.groupKeys[event.keyCode], onExpand?(change) == true { return }
        if KeyPress.isPlain(event), event.keyCode == KeyPress.space, onSpace?() == true { return }
        super.keyDown(with: event)
    }

    /// The Repositories header's sort button takes its own click (the row itself does nothing).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is PartsButton || super.validateProposedFirstResponder(responder, for: event)
    }
}
