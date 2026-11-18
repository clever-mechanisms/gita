import AppKit

/// One column of the merge editor: monospaced text with its chunks shaded full width, changed words marked, and line
/// numbers beside it. Lines have one fixed height, so a line's place is simple arithmetic for the gutters.
@MainActor
final class MergeTextView: NSTextView {
    private(set) var lineHeight: CGFloat = 15
    private(set) var lineCount = 0
    private var bands: [MergeBand] = []
    private(set) weak var lineNumbers: MergeLineNumbers?

    init(editable: Bool, accessibilityLabel: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = editable
        isSelectable = true
        isRichText = false
        allowsUndo = editable
        usesFindBar = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 4, height: 6)
        backgroundColor = Theme.window
        textColor = Theme.text
        setAccessibilityLabel(accessibilityLabel)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Its scroll view with the line numbers on the left.
    func embedded() -> NSView {
        let scroll = Style.scroll(self, horizontal: true)
        scroll.contentView.postsBoundsChangedNotifications = true
        let numbers = MergeLineNumbers(text: self)
        lineNumbers = numbers
        let container = NSView()
        for view in [numbers, scroll] as [NSView] {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            numbers.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            numbers.topAnchor.constraint(equalTo: container.topAnchor),
            numbers.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            numbers.widthAnchor.constraint(equalToConstant: MergeLineNumbers.width),
            scroll.leadingAnchor.constraint(equalTo: numbers.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Shows `pane`; the text is replaced only when it differs (typing keeps its selection and undo).
    func show(_ pane: MergePaneDisplay, font: NSFont) {
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Theme.text, .paragraphStyle: paragraph,
        ]
        typingAttributes = attributes
        defaultParagraphStyle = paragraph
        if let storage = textStorage, string != pane.text || storage.length == 0 {
            storage.setAttributedString(NSAttributedString(string: pane.text, attributes: attributes))
            undoManager?.removeAllActions(withTarget: storage)
            // Size to the new text now: the gutters and the other panes place lines by this view's height.
            if let container = textContainer { layoutManager?.ensureLayout(for: container) }
            sizeToFit()
        }
        lineCount = pane.lineCount
        bands = pane.bands
        markWords(pane.words)
        needsDisplay = true
        lineNumbers?.needsDisplay = true
    }

    private func markWords(_ words: [MergeWord]) {
        guard let layout = layoutManager else { return }
        let length = string.utf16.count
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for word in words where word.range.upperBound <= length {
            layout.addTemporaryAttribute(
                .backgroundColor, value: MergeColors.word(word.tint),
                forCharacterRange: NSRange(location: word.range.lowerBound, length: word.range.count))
        }
    }

    /// The top of `line` in the view's coordinates.
    func y(line: Int) -> CGFloat { textContainerInset.height + CGFloat(line) * lineHeight }

    /// The line at the top of the visible area, with its fraction.
    var topLine: CGFloat {
        guard let clip = enclosingScrollView?.contentView else { return 0 }
        return max(0, (clip.bounds.minY - textContainerInset.height) / lineHeight)
    }

    /// Scrolls so that `line` (fractional) is at the top, keeping the horizontal position.
    func scroll(toLine line: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let maximum = max(0, frame.height - scroll.contentView.bounds.height)
        let target = min(maximum, max(0, textContainerInset.height + line * lineHeight))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolls `line` into the middle when it is out of sight.
    func reveal(line: Int) {
        guard let container = enclosingScrollView else { return }
        let visible = container.contentView.bounds
        let top = y(line: line)
        guard top < visible.minY || top + lineHeight > visible.maxY else { return }
        scroll(toLine: max(0, CGFloat(line) - visible.height / lineHeight / 3))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for band in bands {
            let top = y(line: band.lines.lowerBound)
            if band.lines.isEmpty {
                MergeColors.line(band.tint).setFill()
                NSRect(x: 0, y: top - 1, width: bounds.width, height: 2).fill()
                continue
            }
            let area = NSRect(x: 0, y: top, width: bounds.width, height: CGFloat(band.lines.count) * lineHeight)
            guard area.intersects(rect) else { continue }
            MergeColors.fill(band.tint, done: band.isDone).setFill()
            area.fill()
            if band.isCurrent {
                MergeColors.line(band.tint).setStroke()
                NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }
}

/// The line numbers beside a `MergeTextView`, level with its lines as it scrolls.
@MainActor
final class MergeLineNumbers: NSView {
    static let width: CGFloat = 34
    private weak var text: MergeTextView?

    init(text: MergeTextView) {
        self.text = text
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.inset.setFill()
        bounds.intersection(dirtyRect).fill()
        guard let text, text.lineCount > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TextLines.monospaced(9.5), .foregroundColor: Theme.tertiaryText,
        ]
        let visible = text.visibleRect
        let first = max(0, Int((visible.minY - text.textContainerInset.height) / text.lineHeight))
        let last = min(text.lineCount, Int(ceil((visible.maxY - text.textContainerInset.height) / text.lineHeight)) + 1)
        guard first < last else { return }
        for line in first..<last {
            let label = NSAttributedString(string: String(line + 1), attributes: attributes)
            let size = label.size()
            let top = convert(NSPoint(x: 0, y: text.y(line: line)), from: text).y
            label.draw(at: NSPoint(x: bounds.width - size.width - 6, y: top + (text.lineHeight - size.height) / 2))
        }
    }
}

/// The merge editor's tints, light and dark from the system colours.
@MainActor
enum MergeColors {
    private static func base(_ tint: MergeTint) -> NSColor {
        switch tint {
        case .conflict: .systemRed
        case .modified: .systemBlue
        case .added: .systemGreen
        case .deleted: .systemGray
        }
    }
    static func fill(_ tint: MergeTint, done: Bool) -> NSColor { base(tint).withAlphaComponent(done ? 0.07 : 0.17) }
    static func line(_ tint: MergeTint) -> NSColor { base(tint).withAlphaComponent(0.85) }
    static func word(_ tint: MergeTint) -> NSColor { base(tint).withAlphaComponent(0.32) }
}
