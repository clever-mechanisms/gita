import AppKit

/// A borderless panel button that redraws while the pointer is over it.
@MainActor
class PanelHoverButton: NSButton {
    private(set) var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
    }
    @available(*, unavailable, message: "Panel buttons are built in code")
    required init?(coder _: NSCoder) { fatalError("Panel buttons are built in code") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        HoverTracking.update(self)
    }
    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    private func setHovering(_ hovering: Bool) {
        isHovering = hovering
        needsDisplay = true
    }
}
