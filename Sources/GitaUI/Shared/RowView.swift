import AppKit

/// A view that tracks the mouse to draw a hover fill, toggles on a click anywhere in it and can draw a selection
/// fill. Interactive subviews (buttons) keep their own clicks. With keyboard navigation on, a clickable row takes
/// focus like a button: it draws the focus ring and Space or Return presses it.
class RowView: NSView {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var fill: NSColor? { didSet { needsDisplay = true } }
    var selectionFill: NSColor = Theme.rowSelection
    var bottomSeparator: NSColor? { didSet { needsDisplay = true } }
    var hoverEnabled = true
    private(set) var isHovering = false
    private static let hoverAlpha: CGFloat = 0.55

    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        if isSelected {
            selectionFill.setFill()
            bounds.fill()
        } else if let fill {
            fill.setFill()
            bounds.fill()
        } else if isHovering && hoverEnabled && onClick != nil {
            Deck.hoverFill.withAlphaComponent(Self.hoverAlpha).setFill()
            hoverRect.fill()
        }
        if let bottomSeparator {
            bottomSeparator.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }
    override func mouseEntered(with _: NSEvent) {
        isHovering = true
        needsDisplay = true
    }
    override func mouseExited(with _: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
    /// The part that lights up on hover: where a click acts.
    var hoverRect: NSRect { bounds }
    /// Where a click acts (default: the whole row). A row with content below its line (an expanded card) narrows it.
    func acceptsClick(at _: NSPoint) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), acceptsClick(at: point) else { return }
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() } else if event.clickCount == 1 { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {
        if (onClick == nil && onDoubleClick == nil) || !acceptsClick(at: convert(event.locationInWindow, from: nil)) {
            super.mouseDown(with: event)
        }
    }

    // MARK: Keyboard

    /// Like a native button, a row takes focus from the keyboard (Tab with keyboard navigation on), not from a click.
    override var acceptsFirstResponder: Bool { onClick != nil && NSApp.isFullKeyboardAccessEnabled }
    override func keyDown(with event: NSEvent) {
        if let onClick, KeyPress.isPlain(event), KeyPress.isActivation(event) {
            onClick()
        } else {
            super.keyDown(with: event)
        }
    }
    override func drawFocusRingMask() { hoverRect.fill() }
    override var focusRingMaskBounds: NSRect { hoverRect }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { onClick != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { onClick != nil ? .button : .group }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}
