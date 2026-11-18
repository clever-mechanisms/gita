import AppKit
import GitaCore

/// Rows of avatar · SHA · subject · author, drawn directly (only rows inside the dirty rect), with hover fill,
/// click to select, a tooltip per row and one accessibility button per row, created when VoiceOver asks.
@MainActor
final class MergedCommitList: NSView, NSViewToolTipOwner {
    private enum Metrics {
        static let inset: CGFloat = 10
        static let avatar: CGFloat = 16
        static let gap: CGFloat = 8
        static let authorShare: CGFloat = 0.32
        static let hoverAlpha: CGFloat = 0.55
        static let shortSHA = 7
    }
    private let commits: [GitCommit]
    private let onSelect: (GitCommit) -> Void
    private(set) var hovered: Int?
    private func elements() -> [NSAccessibilityElement] {
        commits.indices.map { row in
            let element = PressableAccessibilityElement()
            element.press = { [weak self] in self?.select(row) }
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel("\(commits[row].subject), \(commits[row].author)")
            element.setAccessibilityFrameInParentSpace(rect(row))
            return element
        }
    }

    init(commits: [GitCommit], onSelect: @escaping (GitCommit) -> Void) {
        self.commits = commits
        self.onSelect = onSelect
        super.init(frame: .zero)
        setAccessibilityRole(.list)
        setAccessibilityElement(true)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("MergedCommitList is built in code") }

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        removeAllToolTips()
        for row in commits.indices { addToolTip(rect(row), owner: self, userData: nil) }
        setAccessibilityChildren(elements())
    }
    private func rect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * Theme.rowHeight, width: bounds.width, height: Theme.rowHeight)
    }
    func row(at point: NSPoint) -> Int? {
        let row = Int(floor(point.y / Theme.rowHeight))
        return commits.indices.contains(row) && point.x >= 0 && point.x <= bounds.width ? row : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit may pass an unbounded rect (drawing for a cache or a print): only the bounds have rows.
        let dirty = dirtyRect.intersection(bounds)
        guard !dirty.isNull, !commits.isEmpty else { return }
        let first = max(0, Int(floor(dirty.minY / Theme.rowHeight)))
        let last = min(commits.count - 1, Int(ceil(dirty.maxY / Theme.rowHeight)))
        guard first <= last else { return }
        for row in first...last { draw(row) }
    }
    private func draw(_ row: Int) {
        let commit = commits[row]
        let line = rect(row)
        if row == hovered {
            Deck.hoverFill.withAlphaComponent(Metrics.hoverAlpha).setFill()
            line.fill()
        }
        var x = line.minX + Metrics.inset
        AvatarPainter.draw(
            commit.author, email: commit.email,
            in: NSRect(x: x, y: line.midY - Metrics.avatar / 2, width: Metrics.avatar, height: Metrics.avatar))
        x += Metrics.avatar + Metrics.gap
        let sha = String(commit.id.prefix(Metrics.shortSHA))
        TextLines.draw(
            sha, font: Theme.mono, color: Theme.secondaryText,
            at: NSPoint(x: x, y: line.midY - Self.height(Theme.mono) / 2))
        x += ceil(TextLines.width(sha, font: Theme.mono)) + Metrics.gap
        let authorWidth = min(
            bounds.width * Metrics.authorShare, ceil(TextLines.width(commit.author, font: Theme.caption)))
        let authorX = line.maxX - Metrics.inset - authorWidth
        TextLines.draw(
            commit.author, font: Theme.caption, color: Theme.secondaryText,
            in: Self.lineRect(x: authorX, midY: line.midY, width: authorWidth, font: Theme.caption))
        TextLines.draw(
            commit.subject, font: Theme.body, color: Theme.text,
            in: Self.lineRect(x: x, midY: line.midY, width: max(0, authorX - Metrics.gap - x), font: Theme.body))
    }
    private static func height(_ font: NSFont) -> CGFloat { font.ascender - font.descender }
    private static func lineRect(x: CGFloat, midY: CGFloat, width: CGFloat, font: NSFont) -> NSRect {
        let height = height(font)
        return NSRect(x: x, y: midY - height / 2, width: width, height: height + 1)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        )
    }
    func setHovered(_ row: Int?) {
        guard row != hovered else { return }
        if let hovered { setNeedsDisplay(rect(hovered)) }
        hovered = row
        if let row { setNeedsDisplay(rect(row)) }
    }
    override func mouseMoved(with event: NSEvent) { setHovered(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { setHovered(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with _: NSEvent) { setHovered(nil) }
    override func mouseDown(with _: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1, let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
        select(row)
    }
    func select(_ row: Int) { onSelect(commits[row]) }

    func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        row(at: point).map { commits[$0].subject } ?? ""
    }
}
