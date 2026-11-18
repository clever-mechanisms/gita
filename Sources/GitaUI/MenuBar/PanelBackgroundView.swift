import AppKit

/// The panel's opaque root view; it hands the panel's ⌘ shortcuts to its controller.
@MainActor
final class PanelBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let controller = nextResponder as? MenuPanelController, controller.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The footer's top hairline.
@MainActor
final class PanelFooterView: NSView {
    override func draw(_: NSRect) {
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
