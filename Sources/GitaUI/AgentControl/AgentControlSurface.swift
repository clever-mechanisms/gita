import AppKit

@MainActor
final class AgentControlSurface: NSView {
    let primary: PartsButton
    init(_ rows: [NSView], header: NSView? = nil, primary: PartsButton, id: String) {
        self.primary = primary
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        let background = ThemedBackgroundView()
        Style.fill(background, in: self)
        let content = AgentControlUI.column(rows, spacing: 12)
        if let header {
            let bodySlot = NSView()
            Deck.pin(content, in: bodySlot, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
            Deck.pin(AgentControlUI.column([header, bodySlot], spacing: 0), in: background)
        } else {
            Deck.pin(content, in: background, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        }
        AgentControlUI.identify(self, id)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard KeyPress.isPlain(event), let window else {
            return super.performKeyEquivalent(with: event)
        }
        let editingText = (window.firstResponder as? NSTextView)?.isEditable == true
        let focusInside = (window.firstResponder as? NSView)?.isDescendant(of: self) == true
        if event.keyCode == KeyPress.returnKey, focusInside,
            !editingText, !primary.isHidden, primary.isEnabled
        {
            return primary.accessibilityPerformPress()
        }
        return super.performKeyEquivalent(with: event)
    }
}
