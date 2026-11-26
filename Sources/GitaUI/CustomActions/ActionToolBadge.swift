import AppKit

@MainActor
final class ActionToolBadge: NSTextField {
    init(_ title: String, color: NSColor) {
        super.init(frame: .zero)
        stringValue = title
        font = Theme.captionEmphasis
        textColor = color
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ActionToolBadge is built in code") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width + 12, height: super.intrinsicContentSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        (textColor ?? Theme.accent).withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        super.draw(dirtyRect)
    }
}
