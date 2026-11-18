import AppKit

/// Header icon buttons (Open Gita, Refresh, •••): SF Symbol, secondary tint, rounded hover.
@MainActor
final class PanelIconButton: PanelHoverButton {
    private static let side: CGFloat = 26

    init(symbol: String, label: String, identifier: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(
            .init(pointSize: 13, weight: .regular))
        contentTintColor = Theme.secondaryText
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("panel." + identifier)
        self.target = target
        self.action = action
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isHighlighted {
            Theme.control.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
