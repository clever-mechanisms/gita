import AppKit

/// A compact one-click action in a row or in the footer: filled accent ("Open ↗"), filled attention ("Terminal"),
/// quiet ("Review") or text alone ("Open Repository…", "Activity ›").
@MainActor
final class PanelChipButton: PanelHoverButton {
    let chip: PanelChip
    var onPress: (() -> Void)?
    private static let iconSide: CGFloat = 12
    private static let height: CGFloat = 20

    init(_ chip: PanelChip) {
        self.chip = chip
        super.init(frame: .zero)
        title = chip.title
        setButtonType(.momentaryChange)
        target = self
        action = #selector(press)
        toolTip = chip.label
        setAccessibilityLabel(chip.label)
        setAccessibilityRole(.button)
    }

    @objc private func press() { onPress?() }

    private var padding: CGFloat { chip.title.isEmpty ? 5 : 8 }
    private var symbolImage: NSImage? {
        chip.symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(
                .init(pointSize: 10, weight: .semibold))
        }
    }
    override var intrinsicContentSize: NSSize {
        let text =
            chip.title.isEmpty
            ? 0 : ceil(NSAttributedString(string: chip.title, attributes: [.font: Theme.captionEmphasis]).size().width)
        let icon: CGFloat = symbolImage == nil ? 0 : Self.iconSide
        let gap: CGFloat = icon > 0 && text > 0 ? 4 : 0
        return NSSize(width: max(Self.height, padding * 2 + icon + gap + text), height: Self.height)
    }

    /// Fill and ink for the chip's style; quiet chips and text alone light up under the pointer.
    private var colors: (background: NSColor, foreground: NSColor) {
        let isLit = isHovering || isHighlighted
        return switch chip.style {
        case .accent: (Theme.accent.withAlphaComponent(isHighlighted ? 0.8 : 1), Theme.window)
        case .attention: (Theme.needsInput.withAlphaComponent(isHighlighted ? 0.8 : 1), Theme.window)
        case .quiet: (isLit ? Theme.selection : Theme.control, Theme.accentText)
        case .link: (isLit ? Theme.control : .clear, Theme.accentText)
        case .subtle: (isLit ? Theme.control : .clear, Theme.secondaryText)
        }
    }

    override func draw(_: NSRect) {
        let (background, foreground) = colors
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        var x = ((bounds.width - intrinsicContentSize.width) / 2).rounded() + padding
        if let image = symbolImage {
            drawSymbol(image, color: foreground, x: x)
            x += chip.title.isEmpty ? Self.iconSide : Self.iconSide + 4
        }
        if !chip.title.isEmpty {
            let text = NSAttributedString(
                string: chip.title, attributes: [.font: Theme.captionEmphasis, .foregroundColor: foreground])
            let lineHeight = ceil(Theme.captionEmphasis.ascender - Theme.captionEmphasis.descender)
            text.draw(at: NSPoint(x: x, y: ((bounds.height - lineHeight) / 2).rounded()))
        }
    }

    private func drawSymbol(_ image: NSImage, color: NSColor, x: CGFloat) {
        let side = Self.iconSide
        let tinted = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(
                in: NSRect(
                    x: (side - image.size.width) / 2, y: (side - image.size.height) / 2, width: image.size.width,
                    height: image.size.height))
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side))
    }
}
