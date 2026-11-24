import AppKit
import GitaCore

/// Single-table row view drawing both the old (left) and new (right) halves of a `SplitDiffRow`.
@MainActor
final class DiffSplitCell: NSView {
    private enum SplitMetrics {
        static let gutterWidth: CGFloat = 46
        static let numberWidth: CGFloat = 36
        static let textOffset: CGFloat = 52
    }

    struct SideInput {
        var line: DiffLine?
        var wordHighlights: [Range<Int>]
        var syntaxTokens: [SyntaxToken]
        var findMatches: [Range<Int>]
        var activeFindMatchIndex: Int?
        var numberText: String
    }

    var row: SplitDiffRow? {
        didSet {
            refreshAccessibility()
            needsDisplay = true
        }
    }
    var fontSize: CGFloat = DiffCell.Metrics.fontSize {
        didSet { if fontSize != oldValue { needsDisplay = true } }
    }
    var tabWidth: Int = CodeFont.defaultTabWidth {
        didSet { if tabWidth != oldValue { needsDisplay = true } }
    }
    var leftFind: (ranges: [Range<Int>], activeIndex: Int?) = ([], nil) {
        didSet { needsDisplay = true }
    }
    var rightFind: (ranges: [Range<Int>], activeIndex: Int?) = ([], nil) {
        didSet { needsDisplay = true }
    }
    var isStageSelectionMarked = false {
        didSet { if isStageSelectionMarked != oldValue { needsDisplay = true } }
    }
    var customActions: [NSAccessibilityCustomAction] = [] {
        didSet { setAccessibilityCustomActions(customActions) }
    }

    override var isFlipped: Bool { true }

    private func refreshAccessibility() {
        let leftDesc = DiffCell.accessibilityDescription(for: row?.left)
        let rightDesc = DiffCell.accessibilityDescription(for: row?.right)
        let combined = [leftDesc, rightDesc].compactMap { $0 }.joined(separator: " | ")
        setAccessibilityLabel(combined.isEmpty ? nil : combined)
    }

    override func draw(_: NSRect) {
        guard let row else { return }
        let halfWidth = floor(bounds.width / 2)
        let leftRect = NSRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        let rightRect = NSRect(
            x: halfWidth + 1, y: 0, width: max(0, bounds.width - halfWidth - 1), height: bounds.height)

        drawHalf(
            SideInput(
                line: row.left, wordHighlights: row.leftWordHighlights, syntaxTokens: row.leftSyntaxTokens,
                findMatches: leftFind.ranges, activeFindMatchIndex: leftFind.activeIndex,
                numberText: row.left?.old ?? ""),
            in: leftRect)
        Theme.separator.setFill()
        NSRect(x: halfWidth, y: 0, width: 1, height: bounds.height).fill()
        drawHalf(
            SideInput(
                line: row.right, wordHighlights: row.rightWordHighlights, syntaxTokens: row.rightSyntaxTokens,
                findMatches: rightFind.ranges, activeFindMatchIndex: rightFind.activeIndex,
                numberText: row.right?.new ?? ""),
            in: rightRect)
    }

    private func drawHalf(_ side: SideInput, in rect: NSRect) {
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let line = side.line else {
            Theme.inset.withAlphaComponent(0.6).setFill()
            rect.fill()
            DiffCell.gutterFill.setFill()
            NSRect(x: rect.minX, y: 0, width: SplitMetrics.gutterWidth, height: rect.height).fill()
            return
        }
        if let tint = DiffCell.tintColor(for: line.kind) {
            tint.setFill()
            rect.fill()
        }
        DiffCell.gutterFill.setFill()
        NSRect(x: rect.minX, y: 0, width: SplitMetrics.gutterWidth, height: rect.height).fill()
        if let bar = DiffCell.gutterBarColor(for: line.kind) {
            bar.setFill()
            NSRect(x: rect.minX, y: 0, width: DiffCell.Metrics.gutterBarWidth, height: rect.height).fill()
        }
        if isStageSelectionMarked && (line.kind == "+" || line.kind == "-") {
            Theme.accent.setFill()
            NSRect(x: rect.minX + SplitMetrics.gutterWidth - 3, y: 0, width: 3, height: rect.height).fill()
        }

        let numberFont = TextLines.monospaced(min(fontSize, 13))
        let numberTop = max(1, (rect.height - DiffCell.Metrics.numberHeight) / 2)
        TextLines.draw(
            side.numberText, font: numberFont, color: .tertiaryLabelColor,
            in: NSRect(
                x: rect.minX + 4, y: numberTop, width: SplitMetrics.numberWidth,
                height: DiffCell.Metrics.numberHeight),
            alignment: .right)

        let shownText = DiffCell.shown(line.text, tabWidth: tabWidth)
        let font = TextLines.monospaced(fontSize)
        let originX = rect.minX + SplitMetrics.textOffset
        DiffCell.drawHighlights(
            DiffCell.HighlightDrawInput(
                rect: rect, rawText: line.text, shownText: shownText, kind: line.kind,
                wordHighlights: side.wordHighlights, findMatches: side.findMatches,
                activeFindMatchIndex: side.activeFindMatchIndex, tabWidth: tabWidth, font: font, originX: originX))
        let textTop = max(1, (rect.height - (font.ascender - font.descender)) / 2 - 0.5)
        DiffCell.drawCodeText(
            DiffCell.CodeDrawInput(
                shownText: shownText, rawText: line.text, kind: line.kind, syntaxTokens: side.syntaxTokens,
                tabWidth: tabWidth, font: font, point: NSPoint(x: originX, y: textTop)))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
