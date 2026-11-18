import AppKit
import GitaCore

/// The subject column of a history row: the graph and the message, with the merge chip, the eye button and the
/// "+N" pill clickable and the whole row read by VoiceOver as one element.
@MainActor
final class HistoryCommitCell: NSView, NSViewToolTipOwner {
    /// What one row shows.
    struct Content {
        var commit: GitCommit
        var row: GraphRow?
        var previous: GraphRow?
        var next: GraphRow?
        var scale: CGFloat
        var isHead: Bool
        var remoteNames: Set<String>
        var merge: MergeFlair?
        var showsMergeLabel = true
    }
    /// The space between the graph and the message, scaled.
    private static let graphGap: CGFloat = 2

    let graph = GraphCell()
    let message = CommitMessageCell()
    /// Hovering the "N commits" chip of a merge (opens the merged-commit list); the rect is in this cell.
    var onMergeHover: ((String, NSRect, NSView) -> Void)?
    var onMergeHoverEnd: (() -> Void)?
    /// Clicking the chip (opens or closes the list when Settings › Git says "Click").
    var onMergeClick: ((String, NSRect, NSView) -> Void)?
    /// Clicking the eye button of an opened merge: fold its commits away again.
    var onMergeHide: ((String) -> Void)?
    /// The "+N" references pill was clicked: list every reference on the commit.
    var onReferencesClick: ((String, NSRect, NSView) -> Void)?
    private(set) var representedCommitID = ""
    private var hoveringChip = false
    /// The tooltip is registered once per size and its text built only when shown (rows are reconfigured on
    /// every scroll; registering a tooltip each time is measurable).
    private var toolTipBounds: NSRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(graph)
        addSubview(message)
        NotificationCenter.default.addObserver(
            self, selector: #selector(avatarsChanged), name: AvatarStore.changed, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(graphLinesChanged), name: GraphCell.lineStyleChanged, object: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("HistoryCommitCell is built in code") }

    @objc private func avatarsChanged() { if graph.merge != nil { graph.needsDisplay = true } }
    @objc private func graphLinesChanged() { graph.needsDisplay = true }

    func configure(_ content: Content) {
        let commit = content.commit
        graph.previous = content.previous
        graph.next = content.next
        representedCommitID = commit.id
        hoveringChip = false
        message.showsMergeLabel = content.showsMergeLabel
        message.merge = content.merge
        graph.scale = content.scale
        graph.isMerge = commit.parents.count > 1 || content.merge?.squashed == true
        graph.isHead = content.isHead
        graph.merge = content.merge
        graph.row = content.row
        message.scale = content.scale
        message.isHead = content.isHead
        message.remoteNames = content.remoteNames
        message.commit = commit
        setAccessibilityLabel(Self.accessibilityLabel(commit, merge: content.merge))
        setAccessibilityCustomActions(
            content.showsMergeLabel && content.merge?.expanded == true ? [hideAction(commit.id)] : nil)
        needsLayout = true
    }

    /// References, then the merge's summary, then the subject.
    static func accessibilityLabel(_ commit: GitCommit, merge: MergeFlair?) -> String {
        (commit.decorations
            + [merge?.tooltip.replacingOccurrences(of: "\n", with: ", "), commit.subject].compactMap { $0 })
            .joined(separator: ", ")
    }
    private func hideAction(_ id: String) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: String(localized: "Hide in History")) { [weak self] in
            self?.onMergeHide?(id)
            return true
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    // MARK: Mouse

    private func inCell(_ rect: NSRect?) -> NSRect? { rect.map { message.convert($0, to: self) } }
    private var chipRect: NSRect? { inCell(message.mergeChipRect) }
    private var hideRect: NSRect? { inCell(message.mergeHideRect) }
    private var overflowRect: NSRect? { inCell(message.refsOverflowRect) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }
    /// Hover feedback for the eye and "+N" buttons, and hover start or end over the merge chip.
    func hover(at point: NSPoint) {
        message.hideHovered = hideRect?.contains(point) ?? false
        message.overflowHovered = overflowRect?.contains(point) ?? false
        let inside = chipRect?.contains(point) ?? false
        guard inside != hoveringChip else { return }
        hoveringChip = inside
        if inside, let rect = chipRect { onMergeHover?(representedCommitID, rect, self) } else { onMergeHoverEnd?() }
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with _: NSEvent) {
        message.hideHovered = false
        message.overflowHovered = false
        if hoveringChip {
            hoveringChip = false
            onMergeHoverEnd?()
        }
    }
    /// Runs the click on the eye, "+N" or merge chip at `point`; false when the click is for the row.
    func click(at point: NSPoint) -> Bool {
        if let rect = hideRect, rect.contains(point) {
            onMergeHide?(representedCommitID)
        } else if let rect = overflowRect, rect.contains(point) {
            onReferencesClick?(representedCommitID, rect, self)
        } else if let rect = chipRect, rect.contains(point) {
            onMergeClick?(representedCommitID, rect, self)
        } else {
            return false
        }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        if !click(at: convert(event.locationInWindow, from: nil)) { super.mouseDown(with: event) }
    }

    // MARK: Tooltip and layout

    func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        if hideRect?.contains(point) == true { return String(localized: "Hide in History") }
        if overflowRect?.contains(point) == true, let commit = message.commit {
            return commit.decorations.joined(separator: "\n")
        }
        if let merge = message.merge, chipRect?.contains(point) == true || graph.frame.contains(point) {
            return merge.tooltip
        }
        if graph.frame.contains(point), let overflow = graph.overflow {
            return String(
                localized:
                    "On lane \(overflow.lane) of \(overflow.lanes). The graph draws the first \(GraphCell.maximumLanes) lanes."
            )
        }
        return message.commit.map { ($0.decorations + [$0.subject]).joined(separator: "\n") } ?? ""
    }
    override func layout() {
        super.layout()
        if toolTipBounds != bounds {
            toolTipBounds = bounds
            removeAllToolTips()
            addToolTip(bounds, owner: self, userData: nil)
        }
        let lastLane = graph.row.map(GraphOverflow.lastLane(of:)) ?? 0
        let width = GraphCell.width(lastLane: lastLane, scale: graph.scale)
        let gap = Self.graphGap * graph.scale
        graph.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        message.frame = NSRect(x: width + gap, y: 0, width: max(0, bounds.width - width - gap), height: bounds.height)
    }
}
