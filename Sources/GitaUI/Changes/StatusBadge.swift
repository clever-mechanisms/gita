import AppKit

/// A file's status letter on a rounded square in the status colour.
@MainActor
final class StatusBadge: NSView {
    private static let cornerRadius: CGFloat = 3.5
    private static let font = NSFont.systemFont(ofSize: 10, weight: .bold)

    var letter = "" { didSet { needsDisplay = true } }
    var color: NSColor = Theme.needsInput { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius
        ).fill()
        let text = NSAttributedString(string: letter, attributes: [.font: Self.font, .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
