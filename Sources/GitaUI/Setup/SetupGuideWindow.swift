import AppKit

/// The Setup Guide's sheet window: the history card's ⌘+ ⌘− ⌘0 ⌘D work while the guide is in front.
@MainActor
final class SetupGuideWindow: NSWindow {
    private static let historyKeys: Set<String> = ["+", "=", "-", "0", "d"]
    var onHistoryShortcut: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if Self.isHistoryShortcut(key: key, flags: event.modifierFlags), onHistoryShortcut?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘ with one of the history keys; ⌘⇧ only for + and = (Zoom In on keyboards where + needs Shift).
    static func isHistoryShortcut(key: String, flags: NSEvent.ModifierFlags) -> Bool {
        let held = flags.intersection([.command, .shift, .option, .control])
        let permitted = held == .command || (held == [.command, .shift] && ["+", "="].contains(key))
        return permitted && historyKeys.contains(key)
    }
}

/// One step in the guide's rail: the current one sits on an accent tint; the arrow keys move to the previous or next
/// step.
@MainActor
final class SetupCardButton: NSButton {
    var onArrow: ((Int) -> Void)?
    var isCurrent = false { didSet { needsDisplay = true } }

    override static var cellClass: AnyClass? {
        get { SetupStepCell.self }
        set { _ = newValue }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            Theme.accent.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }

    override func keyDown(with event: NSEvent) {
        if KeyPress.isPlain(event), let step = KeyPress.arrowStep(event) {
            onArrow?(step)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A rail step's cell: its symbol and title stand in from the edges of the highlight.
@MainActor
final class SetupStepCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect).insetBy(dx: 10, dy: 0)
    }
}

/// Foundation observer removal is safe even if the owning controller is released without an explicit dismissal.
final class SetupObservationBag {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    func add(_ center: NotificationCenter, token: NSObjectProtocol) { tokens.append((center, token)) }
    func removeAll() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}
