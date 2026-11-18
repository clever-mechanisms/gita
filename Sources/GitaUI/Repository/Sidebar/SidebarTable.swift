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
    /// Changes the selected group; false when the selected row is not one (the table then handles the key).
    var onExpand: ((GroupChange) -> Bool)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, index < numberOfRows else { return nil }
        return rowMenu?(index)
    }

    override func keyDown(with event: NSEvent) {
        if Self.returnKeys.contains(event.keyCode) {
            onReturn?()
            return
        }
        if let change = Self.groupKeys[event.keyCode], onExpand?(change) == true { return }
        super.keyDown(with: event)
    }

    /// The Repositories header's sort button takes its own click (the row itself does nothing).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is PartsButton || super.validateProposedFirstResponder(responder, for: event)
    }
}
