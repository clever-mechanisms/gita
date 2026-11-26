import AppKit

@MainActor
final class AgentControlSurface: NSView {
    let primary: PartsButton
    init(_ rows: [NSView], primary: PartsButton, id: String) {
        self.primary = primary
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        let background = ThemedBackgroundView()
        Style.fill(background, in: self)
        Deck.pin(
            AgentControlUI.column(rows, spacing: 12), in: background,
            insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        AgentControlUI.identify(self, id)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard KeyPress.isPlain(event), let window else {
            return super.performKeyEquivalent(with: event)
        }
        if event.keyCode == KeyPress.escape, window is AgentControlWindow {
            if super.performKeyEquivalent(with: event) { return true }
            window.performClose(nil)
            return true
        }
        let editingText = (window.firstResponder as? NSTextView)?.isEditable == true
        let focusInside = (window.firstResponder as? NSView)?.isDescendant(of: self) == true
        if event.keyCode == KeyPress.returnKey, window is AgentControlWindow || focusInside,
            !editingText, !primary.isHidden, primary.isEnabled
        {
            return primary.accessibilityPerformPress()
        }
        return super.performKeyEquivalent(with: event)
    }
}
