import AppKit

/// A plain coloured rectangle (separators, backgrounds) that follows appearance changes.
final class FillView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("FillView is built in code") }

    override func draw(_: NSRect) {
        let path =
            cornerRadius > 0
            ? NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            : NSBezierPath(rect: bounds)
        color.setFill()
        path.fill()
        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
