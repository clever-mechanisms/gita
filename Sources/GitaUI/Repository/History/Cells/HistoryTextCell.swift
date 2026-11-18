import AppKit

/// Date and SHA columns: one line of text centred on the row (drawn; history rows are recycled).
@MainActor
final class HistoryTextCell: NSView, NSViewToolTipOwner {
    private static let inset: CGFloat = 4
    private static let toolTipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter
    }()

    var text = "" {
        didSet {
            guard oldValue != text else { return }
            needsDisplay = true
            setAccessibilityLabel(text)
        }
    }
    /// Date column: the full date as a tooltip, formatted only when it is shown.
    var toolTipDate: Date?
    var font: NSFont = Theme.body { didSet { needsDisplay = true } }
    private let color = Theme.secondaryText
    private var toolTipBounds: NSRect?
    override var isFlipped: Bool { true }

    func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point _: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        toolTipDate.map(Self.toolTipFormatter.string(from:)) ?? ""
    }
    override func layout() {
        super.layout()
        if toolTipBounds != bounds {
            toolTipBounds = bounds
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
    }
    override func draw(_: NSRect) {
        let height = font.ascender - font.descender
        TextLines.draw(
            text, font: font, color: color,
            in: NSRect(
                x: Self.inset, y: (bounds.height - height) / 2, width: max(0, bounds.width - Self.inset * 2),
                height: height + 1))
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
