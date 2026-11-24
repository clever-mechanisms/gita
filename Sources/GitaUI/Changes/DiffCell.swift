import AppKit
import CoreText
import GitaCore

/// One diff line: a tint for added, removed and hunk-header lines, a 2 pt gutter bar, line numbers, optional word
/// and find highlights, then the text.
@MainActor
final class DiffCell: NSView {
    enum Metrics {
        static let gutterWidth: CGFloat = 83
        static let gutterBarWidth: CGFloat = 2
        static let numberColumn: CGFloat = 39
        static let numberWidth: CGFloat = 35
        static let numberHeight: CGFloat = 16
        static let textX: CGFloat = 92
        static let fontSize: CGFloat = 11
        static let tintAlpha: CGFloat = 0.14
        static let wordTintAlpha: CGFloat = 0.30
    }

    private static let tints: [Character: NSColor] = [
        "+": NSColor.systemGreen.withAlphaComponent(Metrics.tintAlpha),
        "-": NSColor.systemRed.withAlphaComponent(Metrics.tintAlpha),
        "@": NSColor.systemBlue.withAlphaComponent(Metrics.tintAlpha),
    ]
    private static let wordTints: [Character: NSColor] = [
        "+": NSColor.systemGreen.withAlphaComponent(Metrics.wordTintAlpha),
        "-": NSColor.systemRed.withAlphaComponent(Metrics.wordTintAlpha),
    ]
    private static let gutterBars: [Character: NSColor] = [
        "+": .systemGreen,
        "-": .systemRed,
    ]
    static let findFill = NSColor.systemYellow.withAlphaComponent(0.28)
    static let activeFindFill = Theme.needsInput.withAlphaComponent(0.55)
    private static let baselineLayout = NSLayoutManager()

    /// Where the line numbers' grey gutter ends.
    static let gutterWidth = Metrics.gutterWidth
    static let gutterFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)

    static func tintColor(for kind: Character) -> NSColor? { tints[kind] }
    static func wordTintColor(for kind: Character) -> NSColor? { wordTints[kind] }
    static func gutterBarColor(for kind: Character) -> NSColor? { gutterBars[kind] }

    var line: DiffLine? {
        didSet { refreshDisplay() }
    }
    var isBlobLine = false {
        didSet { refreshAccessibility() }
    }
    var fontSize: CGFloat = Metrics.fontSize {
        didSet { if fontSize != oldValue { needsDisplay = true } }
    }
    var tabWidth: Int = CodeFont.defaultTabWidth {
        didSet { if tabWidth != oldValue { refreshDisplay() } }
    }
    var wordHighlights: [Range<Int>] = [] {
        didSet { if wordHighlights != oldValue { needsDisplay = true } }
    }
    var syntaxTokens: [SyntaxToken] = [] {
        didSet { if syntaxTokens != oldValue { needsDisplay = true } }
    }
    var findMatches: [Range<Int>] = [] {
        didSet { if findMatches != oldValue { needsDisplay = true } }
    }
    var activeFindMatchIndex: Int? {
        didSet { if activeFindMatchIndex != oldValue { needsDisplay = true } }
    }
    var isStageSelectionMarked = false {
        didSet { if isStageSelectionMarked != oldValue { needsDisplay = true } }
    }
    /// Extra room between the gutter and the text (the review's + sits there).
    var textInset: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var customActions: [NSAccessibilityCustomAction] = [] {
        didSet { setAccessibilityCustomActions(customActions) }
    }

    private var shownText = ""
    override var isFlipped: Bool { true }

    private func refreshDisplay() {
        shownText = line.map { Self.shown($0.text, tabWidth: tabWidth) } ?? ""
        refreshAccessibility()
        needsDisplay = true
    }

    private func refreshAccessibility() {
        setAccessibilityLabel(Self.accessibilityDescription(for: line, isBlob: isBlobLine))
    }

    /// Tabs drawn as `tabWidth` spaces (Core Text lines have no tab stops).
    static func shown(_ text: String, tabWidth: Int = CodeFont.defaultTabWidth) -> String {
        guard text.contains("\t") else { return text }
        let spaces = String(repeating: " ", count: max(1, tabWidth))
        return text.replacingOccurrences(of: "\t", with: spaces)
    }

    /// Maps UTF-16 ranges in `text` to UTF-16 ranges in the tab-expanded string.
    static func mapRanges(_ ranges: [Range<Int>], in text: String, tabWidth: Int) -> [Range<Int>] {
        let width = max(1, tabWidth)
        guard !ranges.isEmpty, width != 1, text.contains("\t") else { return ranges }
        var map: [Int] = []
        map.reserveCapacity(text.utf16.count + 1)
        var expanded = 0
        for codeUnit in text.utf16 {
            map.append(expanded)
            expanded += (codeUnit == 9 ? width : 1)
        }
        map.append(expanded)
        let maxIndex = map.count - 1
        return ranges.compactMap { range in
            let low = max(0, min(maxIndex, range.lowerBound))
            let high = max(low, min(maxIndex, range.upperBound))
            return low < high ? map[low]..<map[high] : nil
        }
    }

    static func accessibilityDescription(for line: DiffLine?, isBlob: Bool = false) -> String? {
        guard let line else { return nil }
        switch line.kind {
        case "+":
            let code = String(line.text.dropFirst())
            return line.new.isEmpty
                ? String(localized: "Added: \(code)")
                : String(localized: "Added, line \(line.new): \(code)")
        case "-":
            let code = String(line.text.dropFirst())
            return line.old.isEmpty
                ? String(localized: "Removed: \(code)")
                : String(localized: "Removed, line \(line.old): \(code)")
        case " ":
            let stripPrefix = !isBlob && line.hunkIndex != nil && line.text.hasPrefix(" ")
            let code = stripPrefix ? String(line.text.dropFirst()) : line.text
            let number = line.new.isEmpty ? line.old : line.new
            return number.isEmpty ? code : String(localized: "Line \(number): \(code)")
        case "@":
            return String(localized: "Hunk: \(line.text)")
        default:
            return line.text
        }
    }

    override func draw(_: NSRect) {
        guard let line else { return }
        if let tint = Self.tints[line.kind] {
            tint.setFill()
            bounds.fill()
        }
        Self.gutterFill.setFill()
        NSRect(x: 0, y: 0, width: Metrics.gutterWidth, height: bounds.height).fill()
        if let bar = Self.gutterBars[line.kind] {
            bar.setFill()
            NSRect(x: 0, y: 0, width: Metrics.gutterBarWidth, height: bounds.height).fill()
        }
        if isStageSelectionMarked {
            Theme.accent.setFill()
            NSRect(x: Metrics.gutterWidth - 3, y: 0, width: 3, height: bounds.height).fill()
        }
        let numberFont = TextLines.monospaced(min(fontSize, 13))
        let numberTop = max(1, (bounds.height - Metrics.numberHeight) / 2)
        for (index, value) in [line.old, line.new].enumerated() {
            TextLines.draw(
                value, font: numberFont, color: .tertiaryLabelColor,
                in: NSRect(
                    x: CGFloat(index) * Metrics.numberColumn, y: numberTop, width: Metrics.numberWidth,
                    height: Metrics.numberHeight),
                alignment: .right)
        }
        let font = TextLines.monospaced(fontSize)
        let originX = Metrics.textX + textInset
        Self.drawHighlights(
            HighlightDrawInput(
                rect: bounds, rawText: line.text, shownText: shownText, kind: line.kind,
                wordHighlights: wordHighlights, findMatches: findMatches, activeFindMatchIndex: activeFindMatchIndex,
                tabWidth: tabWidth, font: font, originX: originX))
        let textTop = max(1, (bounds.height - (font.ascender - font.descender)) / 2 - 0.5)
        Self.drawCodeText(
            CodeDrawInput(
                shownText: shownText, rawText: line.text, kind: line.kind, syntaxTokens: syntaxTokens,
                tabWidth: tabWidth, font: font, point: NSPoint(x: originX, y: textTop)))
    }

    struct CodeDrawInput {
        var shownText: String
        var rawText: String
        var kind: Character
        var syntaxTokens: [SyntaxToken]
        var tabWidth: Int
        var font: NSFont
        var point: NSPoint
    }

    struct HighlightDrawInput {
        var rect: NSRect
        var rawText: String
        var shownText: String
        var kind: Character
        var wordHighlights: [Range<Int>]
        var findMatches: [Range<Int>]
        var activeFindMatchIndex: Int?
        var tabWidth: Int
        var font: NSFont
        var originX: CGFloat
    }

    static func drawCodeText(_ input: CodeDrawInput) {
        guard !input.shownText.isEmpty else { return }
        if input.kind == "@" {
            TextLines.draw(input.shownText, font: input.font, color: .systemBlue, at: input.point)
            return
        }
        guard !input.syntaxTokens.isEmpty else {
            TextLines.draw(input.shownText, font: input.font, color: .labelColor, at: input.point)
            return
        }
        let attributed = NSMutableAttributedString(
            string: input.shownText, attributes: [.font: input.font, .foregroundColor: NSColor.labelColor])
        let mappedRanges = mapRanges(input.syntaxTokens.map(\.range), in: input.rawText, tabWidth: input.tabWidth)
        let length = input.shownText.utf16.count
        for (token, range) in zip(input.syntaxTokens, mappedRanges) where range.upperBound <= length {
            attributed.addAttribute(
                .foregroundColor, value: token.kind.color,
                range: NSRange(location: range.lowerBound, length: range.count))
        }
        guard let context = NSGraphicsContext.current else { return }
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let cg = context.cgContext
        cg.saveGState()
        let offset = baselineLayout.defaultBaselineOffset(for: input.font)
        if context.isFlipped {
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: input.point.x, y: input.point.y + offset)
        } else {
            cg.textMatrix = .identity
            cg.textPosition = CGPoint(x: input.point.x, y: input.point.y - offset)
        }
        CTLineDraw(ctLine, cg)
        cg.restoreGState()
    }

    static func drawHighlights(_ input: HighlightDrawInput) {
        let wordRanges = mapRanges(input.wordHighlights, in: input.rawText, tabWidth: input.tabWidth)
        let findRanges = mapRanges(input.findMatches, in: input.rawText, tabWidth: input.tabWidth)
        guard !wordRanges.isEmpty || !findRanges.isEmpty, !input.shownText.isEmpty else { return }
        let attributes: [CFString: Any] = [kCTFontAttributeName: input.font]
        guard let attributed = CFAttributedStringCreate(nil, input.shownText as CFString, attributes as CFDictionary)
        else { return }
        let ctLine = CTLineCreateWithAttributedString(attributed)
        if let wordColor = wordTintColor(for: input.kind) {
            for range in wordRanges {
                fillRange(range, in: ctLine, originX: input.originX, rowHeight: input.rect.height, color: wordColor)
            }
        }
        for (index, range) in findRanges.enumerated() {
            let color = index == input.activeFindMatchIndex ? activeFindFill : findFill
            fillRange(range, in: ctLine, originX: input.originX, rowHeight: input.rect.height, color: color)
        }
    }

    private static func fillRange(
        _ range: Range<Int>, in ctLine: CTLine, originX: CGFloat, rowHeight: CGFloat, color: NSColor
    ) {
        let start = originX + CGFloat(CTLineGetOffsetForStringIndex(ctLine, range.lowerBound, nil))
        let end = originX + CGFloat(CTLineGetOffsetForStringIndex(ctLine, range.upperBound, nil))
        let rect = NSRect(x: start, y: 1, width: max(2, end - start), height: rowHeight - 2)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
