import AppKit

@MainActor
final class AgentControlPill: NSView {
    private enum Palette {
        case explicit(fill: NSColor, border: NSColor)
        case tinted(NSColor)
    }

    private let label = Deck.label("", font: Theme.captionEmphasis)
    private let icon = NSImageView()
    private var mark: AgentControlMark?
    private var palette = Palette.explicit(fill: .clear, border: .clear)

    init() {
        super.init(frame: .zero)
        Deck.pin(
            Deck.hstack([icon, label], spacing: 4), in: self,
            insets: NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    func update(_ mark: AgentControlMark, fill: NSColor, border: NSColor) {
        self.mark = mark
        palette = .explicit(fill: fill, border: border)
        applyMark(mark)
    }

    func update(_ mark: AgentControlMark) {
        self.mark = mark
        palette = .tinted(mark.color)
        applyMark(mark)
    }

    private func applyMark(_ mark: AgentControlMark) {
        label.stringValue = mark.title
        label.textColor = mark.color
        icon.setSymbol(mark.symbol, size: 12, weight: .regular, color: mark.color)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let mark { icon.setSymbol(mark.symbol, size: 12, weight: .regular, color: mark.color) }
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let colors: (fill: NSColor, border: NSColor) =
            switch palette {
            case .explicit(let fill, let border): (fill, border)
            case .tinted(let color): (color.withAlphaComponent(0.12), color.withAlphaComponent(0.35))
            }
        colors.fill.setFill()
        path.fill()
        colors.border.setStroke()
        path.stroke()
    }
}

extension AgentControlMark {
    var pill: AgentControlPill {
        let pill = AgentControlPill()
        pill.update(self)
        return pill
    }
}
