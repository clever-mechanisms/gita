import AppKit

/// A view that fills itself with a theme colour (the window background by default) and redraws when the appearance
/// changes.
final class ThemedBackgroundView: NSView {
    var color: NSColor = Theme.window { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
