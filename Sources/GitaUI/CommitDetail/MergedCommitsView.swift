import AppKit
import GitaCore

/// The merged-commit list shown when hovering or clicking a merge's "N commits" chip. Built for the hover path:
/// a fixed frame (no Auto Layout pass) and one list view that draws only its visible rows, so even a 200-commit
/// merge opens in about a millisecond.
@MainActor
final class MergedCommitsView: NSView {
    private enum Metrics {
        static let width: CGFloat = 560
        static let insets = NSEdgeInsets(top: 10, left: 6, bottom: 12, right: 6)
        static let visibleRows = 12
        static let titleGap: CGFloat = 6
        static let titleInset: CGFloat = 10
        static let linkGap: CGFloat = 12
    }
    var onHover: ((Bool) -> Void)?
    private let size: NSSize

    static func title(count: Int, squashed: Bool) -> String {
        switch (squashed, count == 1) {
        case (true, true): String(localized: "1 squashed commit")
        case (true, false): String(localized: "\(count) squashed commits")
        case (false, true): String(localized: "1 merged commit")
        case (false, false): String(localized: "\(count) merged commits")
        }
    }

    /// `action`: a link at the end of the title row (Show in History / Hide in History in a collapsed history).
    init(
        commits: [GitCommit], squashed: Bool = false, action: (title: String, run: () -> Void)? = nil,
        onSelect: @escaping (GitCommit) -> Void
    ) {
        let insets = Metrics.insets
        let title = Deck.sectionTitle(Self.title(count: commits.count, squashed: squashed))
        let titleHeight = ceil(title.intrinsicContentSize.height)
        let listWidth = Metrics.width - insets.left - insets.right
        let listHeight = CGFloat(min(commits.count, Metrics.visibleRows)) * Theme.rowHeight
        size = NSSize(
            width: Metrics.width, height: insets.top + titleHeight + Metrics.titleGap + listHeight + insets.bottom)
        super.init(frame: NSRect(origin: .zero, size: size))
        var titleWidth = listWidth - 2 * Metrics.titleInset
        if let action {
            let link = PartsButton.link(action.title, action: action.run)
            link.setAccessibilityIdentifier("history.mergedCommits.toggle")
            let linkSize = link.fittingSize
            link.frame = NSRect(
                x: insets.left + listWidth - Metrics.titleInset - linkSize.width,
                y: insets.top + floor((titleHeight - linkSize.height) / 2), width: linkSize.width,
                height: linkSize.height)
            addSubview(link)
            titleWidth -= linkSize.width + Metrics.linkGap
        }
        title.frame = NSRect(x: insets.left + Metrics.titleInset, y: insets.top, width: titleWidth, height: titleHeight)
        addSubview(title)
        let list = MergedCommitList(commits: commits, onSelect: onSelect)
        let listFrame = NSRect(
            x: insets.left, y: insets.top + titleHeight + Metrics.titleGap, width: listWidth, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: listWidth, height: CGFloat(commits.count) * Theme.rowHeight)
        if commits.count > Metrics.visibleRows {
            let scroll = NSScrollView(frame: listFrame)
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.contentView = FlippedClipView()
            scroll.contentView.drawsBackground = false
            scroll.documentView = list
            addSubview(scroll)
        } else {
            list.frame = listFrame
            addSubview(list)
        }
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("MergedCommitsView is built in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size }
    override var fittingSize: NSSize { size }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with _: NSEvent) { onHover?(true) }
    override func mouseExited(with _: NSEvent) { onHover?(false) }
}

@MainActor
private final class FlippedClipView: NSClipView { override var isFlipped: Bool { true } }
