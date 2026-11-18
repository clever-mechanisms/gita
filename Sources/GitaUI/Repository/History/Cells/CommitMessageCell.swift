import AppKit
import GitaCore

/// A history row's message: merge flair, reference pills and subject, drawn from `CommitMessageLayout`. The row's
/// tooltip and accessibility come from `HistoryCommitCell`.
@MainActor
final class CommitMessageCell: NSView {
    private enum Metrics {
        static let pillRadius: CGFloat = 4
        static let mergeFill: CGFloat = 0.12
        static let mergeHoverFill: CGFloat = 0.26
        static let mergeBorder: CGFloat = 0.4
        static let overflowFill: CGFloat = 0.1
        static let overflowHoverFill: CGFloat = 0.2
        static let overflowBorder: CGFloat = 0.35
        static let cloudAlpha: CGFloat = 0.8
        static let mergeGlyph: CGFloat = 11
        static let smallGlyph: CGFloat = 9
    }

    var commit: GitCommit? { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    var isHead = false { didSet { needsDisplay = true } }
    var remoteNames: Set<String> = [] { didSet { if oldValue != remoteNames { cachedBadges = nil } } }
    var merge: MergeFlair? { didSet { if oldValue != merge { needsDisplay = true } } }
    var showsMergeLabel = true { didSet { if oldValue != showsMergeLabel { needsDisplay = true } } }
    /// Where the last drawing put the merge chip, the eye button of an opened merge and the "+N" pill.
    private(set) var mergeChipRect: NSRect?
    private(set) var mergeHideRect: NSRect?
    private(set) var refsOverflowRect: NSRect?
    var hideHovered = false {
        didSet { if oldValue != hideHovered, let rect = mergeHideRect { setNeedsDisplay(rect) } }
    }
    var overflowHovered = false {
        didSet { if oldValue != overflowHovered, let rect = refsOverflowRect { setNeedsDisplay(rect) } }
    }
    private var cachedBadges: (id: String, decorations: [String], badges: [ReferenceBadge])?
    override var isFlipped: Bool { true }

    private func badges(_ commit: GitCommit) -> [ReferenceBadge] {
        if let cached = cachedBadges, cached.id == commit.id, cached.decorations == commit.decorations {
            return cached.badges
        }
        let badges = ReferenceBadge.group(commit.decorations, remoteNames: remoteNames)
        cachedBadges = (commit.id, commit.decorations, badges)
        return badges
    }

    override func draw(_: NSRect) {
        guard let commit else {
            mergeChipRect = nil
            mergeHideRect = nil
            refsOverflowRect = nil
            return
        }
        let layout = CommitMessageLayout(
            size: bounds.size, scale: scale, merge: showsMergeLabel ? merge : nil, badges: badges(commit),
            isHead: isHead)
        mergeChipRect = layout.merge?.rect
        mergeHideRect = layout.merge?.hideButton
        refsOverflowRect = layout.overflow?.rect
        if let merge = layout.merge { draw(merge) }
        for badge in layout.badges { draw(badge) }
        if let overflow = layout.overflow { draw(overflow) }
        TextLines.draw(
            commit.subject, font: CommitMessageLayout.subjectFont(scale, isHead: isHead), color: Theme.text,
            in: layout.subjectRect)
    }

    private func draw(_ merge: CommitMessageLayout.Merge) {
        let color = HistoryTint.mergeLabel()
        let border = color.withAlphaComponent(Metrics.mergeBorder)
        let radius = merge.rect.height / 2
        Self.pill(merge.rect, radius: radius, fill: color.withAlphaComponent(Metrics.mergeFill), border: border)
        if let glyph = Deck.symbol(
            "arrow.triangle.merge", size: Metrics.mergeGlyph * scale, weight: .semibold, color: color)
        {
            GlyphDrawing.drawCentered(glyph, in: merge.iconBox)
        }
        TextLines.draw(merge.text, font: CommitMessageLayout.pillFont(scale), color: color, in: merge.textRect)
        guard let button = merge.hideButton else { return }
        let circle = NSBezierPath(ovalIn: button.insetBy(dx: 0.5, dy: 0.5))
        color.withAlphaComponent(hideHovered ? Metrics.mergeHoverFill : Metrics.mergeFill).setFill()
        circle.fill()
        border.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if let glyph = Deck.symbol(
            "eye.slash", size: Metrics.smallGlyph * scale, weight: .semibold, color: color)
        {
            GlyphDrawing.drawCentered(glyph, in: button)
        }
    }

    private func draw(_ badge: CommitMessageLayout.Badge) {
        let colors = Deck.pillColors(badge.kind)
        Self.pill(badge.rect, radius: Metrics.pillRadius, fill: colors.fill, border: colors.border)
        TextLines.draw(badge.text, font: CommitMessageLayout.pillFont(scale), color: colors.text, in: badge.textRect)
        if let box = badge.cloudBox,
            let glyph = Deck.symbol(
                "cloud", size: Metrics.smallGlyph * scale, weight: .semibold,
                color: colors.text.withAlphaComponent(Metrics.cloudAlpha))
        {
            GlyphDrawing.drawCentered(glyph, in: box)
        }
    }

    private func draw(_ overflow: CommitMessageLayout.Overflow) {
        Self.pill(
            overflow.rect, radius: Metrics.pillRadius,
            fill: Theme.secondaryText.withAlphaComponent(
                overflowHovered ? Metrics.overflowHoverFill : Metrics.overflowFill),
            border: Theme.secondaryText.withAlphaComponent(Metrics.overflowBorder))
        TextLines.draw(
            overflow.text, font: CommitMessageLayout.overflowFont(scale), color: Theme.text, in: overflow.textRect)
    }

    private static func pill(_ rect: NSRect, radius: CGFloat, fill: NSColor, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
