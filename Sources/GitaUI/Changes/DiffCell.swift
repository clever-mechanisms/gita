import AppKit
import GitaCore

/// One diff line: a tint for added, removed and hunk-header lines, both line numbers in a gutter, then the text.
@MainActor
final class DiffCell: NSView {
    private enum Metrics {
        static let gutterWidth: CGFloat = 83
        static let numberColumn: CGFloat = 39
        static let numberWidth: CGFloat = 35
        static let numberHeight: CGFloat = 16
        static let top: CGFloat = 3
        static let textX: CGFloat = 92
        static let fontSize: CGFloat = 11
        static let tintAlpha: CGFloat = 0.09
        static let tabSpaces = "    "
    }
    private static let tints: [Character: NSColor] = [
        "+": NSColor.systemGreen.withAlphaComponent(Metrics.tintAlpha),
        "-": NSColor.systemRed.withAlphaComponent(Metrics.tintAlpha),
        "@": NSColor.systemBlue.withAlphaComponent(Metrics.tintAlpha),
    ]
    /// Where the line numbers' grey gutter ends.
    static let gutterWidth = Metrics.gutterWidth
    private static let gutter = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)

    var line: DiffLine? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(line?.text)
            shownText = line.map { Self.shown($0.text) } ?? ""
        }
    }
    private var shownText = ""
    /// Extra room between the gutter and the text (the review's + sits there).
    var textInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    override var isFlipped: Bool { true }

    /// Tabs drawn as four spaces (Core Text lines have no tab stops).
    static func shown(_ text: String) -> String {
        text.contains("\t") ? text.replacingOccurrences(of: "\t", with: Metrics.tabSpaces) : text
    }

    override func draw(_: NSRect) {
        guard let line else { return }
        if let tint = Self.tints[line.kind] {
            tint.setFill()
            bounds.fill()
        }
        Self.gutter.setFill()
        NSRect(x: 0, y: 0, width: Metrics.gutterWidth, height: bounds.height).fill()
        let font = TextLines.monospaced(Metrics.fontSize)
        for (index, value) in [line.old, line.new].enumerated() {
            TextLines.draw(
                value, font: font, color: .tertiaryLabelColor,
                in: NSRect(
                    x: CGFloat(index) * Metrics.numberColumn, y: Metrics.top, width: Metrics.numberWidth,
                    height: Metrics.numberHeight),
                alignment: .right)
        }
        TextLines.draw(
            shownText, font: font, color: line.kind == "@" ? .systemBlue : .labelColor,
            at: NSPoint(x: Metrics.textX + textInset, y: Metrics.top))
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
