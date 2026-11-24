import AppKit
import GitaCore

/// One line in `BlameView`: age heat bar (`▇▅▂`), block commit/author/date header, line number, and source text.
@MainActor
final class BlameCell: NSView {
    enum Metrics {
        static let metadataWidth: CGFloat = 172
        static let lineNumberWidth: CGFloat = 44
        static let gutterWidth: CGFloat = metadataWidth + lineNumberWidth
        static let heatWidth: CGFloat = 4
        static let textInset: CGFloat = 8
        static let shortSHA = 7
    }

    var annotation: BlameLineAnnotation? {
        didSet {
            refreshDisplay()
        }
    }
    var heatLevel = 0 {
        didSet {
            if heatLevel != oldValue {
                toolTip = Self.tooltipText(for: annotation, heatLevel: heatLevel)
                needsDisplay = true
            }
        }
    }
    var fontSize: CGFloat = 11 {
        didSet {
            if fontSize != oldValue { needsDisplay = true }
        }
    }
    var tabWidth: Int = CodeFont.defaultTabWidth {
        didSet {
            if tabWidth != oldValue { refreshDisplay() }
        }
    }
    var isBlockHighlighted = false {
        didSet {
            if isBlockHighlighted != oldValue { needsDisplay = true }
        }
    }

    private var shownText = ""
    override var isFlipped: Bool { true }

    private func refreshDisplay() {
        shownText = annotation.map { Self.expandTabs($0.text, tabWidth: tabWidth) } ?? ""
        toolTip = Self.tooltipText(for: annotation, heatLevel: heatLevel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.accessibilityText(for: annotation))
        needsDisplay = true
    }

    static func tooltipText(for annotation: BlameLineAnnotation?, heatLevel: Int = 0) -> String? {
        guard let commit = annotation?.commit else { return nil }
        if commit.isUncommitted { return String(localized: "Uncommitted working-tree changes") }
        let identity = commit.email.isEmpty ? commit.author : "\(commit.author) <\(commit.email)>"
        let sha = String(commit.id.prefix(Metrics.shortSHA))
        let heat = heatGlyph(level: heatLevel)
        return commit.summary.isEmpty
            ? "\(heat) \(sha) · \(identity)"
            : "\(heat) \(sha) · \(commit.summary)\n\(identity)"
    }

    static func expandTabs(_ text: String, tabWidth: Int) -> String {
        guard text.contains("\t") else { return text }
        return text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(1, tabWidth)))
    }

    static func heatGlyph(level: Int) -> String {
        switch level {
        case 2: "▇"
        case 1: "▅"
        default: "▂"
        }
    }

    static func accessibilityText(for annotation: BlameLineAnnotation?) -> String? {
        guard let annotation else { return nil }
        guard let commit = annotation.commit else {
            return String(localized: "Line \(annotation.lineNumber): \(annotation.text)")
        }
        let author = commit.isUncommitted ? String(localized: "Uncommitted") : commit.author
        return String(localized: "Line \(annotation.lineNumber), \(author): \(annotation.text)")
    }

    override func draw(_: NSRect) {
        guard let annotation else { return }
        if isBlockHighlighted {
            Theme.rowSelection.withAlphaComponent(0.55).setFill()
            bounds.fill()
        }
        Theme.inset.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: Metrics.gutterWidth, height: bounds.height).fill()

        if annotation.isBlockStart && annotation.lineNumber > 1 {
            Theme.separator.withAlphaComponent(0.6).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }

        drawHeatBar(for: annotation)
        if annotation.isBlockStart, let commit = annotation.commit {
            drawMetadata(commit)
        }
        drawLineNumber(annotation.lineNumber)
        drawCodeLine()
    }

    private func drawHeatBar(for annotation: BlameLineAnnotation) {
        guard annotation.commit != nil else { return }
        let color = Self.heatColor(level: heatLevel)
        color.setFill()
        let barHeight: CGFloat =
            switch heatLevel {
            case 2: bounds.height
            case 1: max(8, bounds.height * 0.68)
            default: max(5, bounds.height * 0.42)
            }
        let y = annotation.isBlockStart ? (bounds.height - barHeight) : 0
        NSRect(x: 2, y: y, width: Metrics.heatWidth, height: annotation.isBlockStart ? barHeight : bounds.height).fill()
    }

    private func drawMetadata(_ commit: BlameCommitInfo) {
        let captionFont = TextLines.monospaced(10)
        let textTop = max(1, (bounds.height - (captionFont.ascender - captionFont.descender)) / 2 - 0.5)
        let shaText = commit.isUncommitted ? String(localized: "Working") : String(commit.id.prefix(Metrics.shortSHA))
        let shaColor = commit.isUncommitted ? Theme.needsInputText : Theme.accentText
        TextLines.draw(
            shaText, font: captionFont, color: shaColor,
            in: NSRect(x: 10, y: textTop, width: 52, height: bounds.height), alignment: .left)

        let author = commit.isUncommitted ? String(localized: "You") : Self.shortAuthor(commit.author)
        let metaFont = TextLines.system(10.5)
        TextLines.draw(
            author, font: metaFont, color: Theme.secondaryText,
            in: NSRect(x: 64, y: textTop, width: 64, height: bounds.height), alignment: .left)

        let dateText = commit.isUncommitted ? "" : DeckFormat.relative(commit.date)
        TextLines.draw(
            dateText, font: metaFont, color: Theme.tertiaryText,
            in: NSRect(x: 128, y: textTop, width: 40, height: bounds.height), alignment: .right)
    }

    private func drawLineNumber(_ number: Int) {
        let numberFont = TextLines.monospaced(min(fontSize, 12))
        let top = max(1, (bounds.height - (numberFont.ascender - numberFont.descender)) / 2 - 0.5)
        TextLines.draw(
            "\(number)", font: numberFont, color: .tertiaryLabelColor,
            in: NSRect(x: Metrics.metadataWidth + 2, y: top, width: Metrics.lineNumberWidth - 8, height: bounds.height),
            alignment: .right)
    }

    private func drawCodeLine() {
        let font = TextLines.monospaced(fontSize)
        let top = max(1, (bounds.height - (font.ascender - font.descender)) / 2 - 0.5)
        TextLines.draw(
            shownText, font: font, color: .labelColor,
            at: NSPoint(x: Metrics.gutterWidth + Metrics.textInset, y: top))
    }

    static func heatColor(level: Int) -> NSColor {
        switch level {
        case 2: Theme.needsInputText
        case 1: Theme.running
        default: Theme.tertiaryText
        }
    }

    static func shortAuthor(_ name: String) -> String {
        let parts = name.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return name }
        return "\(parts[0]) \(parts[1].prefix(1))."
    }
}
