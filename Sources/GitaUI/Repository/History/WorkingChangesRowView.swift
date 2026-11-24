import AppKit
import GitaCore

/// Pinned `26 pt` Working Changes row shown above the history clip view whenever the scope contains HEAD and the
/// working tree is dirty. Draws a dashed hollow node at HEAD's lane x — never a fake `GitCommit` row.
@MainActor
final class WorkingChangesRowView: NSView {
    static let height: CGFloat = 26
    private enum Metrics {
        static let nodeRadius: CGFloat = 4
        static let nodeLineWidth: CGFloat = 1.75
        static let dashPattern: [CGFloat] = [2.5, 2.0]
        static let commitButtonHeight: CGFloat = 20
        static let trailingInset: CGFloat = 12
    }

    var state = WorkingChangesRowState(
        .init(
            snapshot: nil, displayedCommits: [], graphs: [], isSearching: false, isAuthorFiltering: false,
            focusedReference: nil, branchFilters: BranchFilters(), isSelected: false))
    {
        didSet {
            guard state != oldValue else { return }
            applyState()
        }
    }
    var scale: CGFloat = 1 {
        didSet {
            if scale != oldValue {
                needsLayout = true
                needsDisplay = true
            }
        }
    }
    var laneCount = 1 {
        didSet {
            if laneCount != oldValue {
                needsLayout = true
                needsDisplay = true
            }
        }
    }
    var horizontalOffset: CGFloat = 0 {
        didSet {
            if abs(horizontalOffset - oldValue) > 0.5 {
                needsLayout = true
                needsDisplay = true
            }
        }
    }

    var onSelect: (() -> Void)?
    var onCommit: (() -> Void)?

    private let label = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    let commitButton = PartsButton(
        [.text(String(localized: "Commit…"), font: Theme.caption, color: Theme.text)],
        background: .hover, accessibility: String(localized: "Open Local Changes to Commit"))
    private var hovering = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commitButton.fixedHeight = Metrics.commitButtonHeight
        commitButton.horizontalPadding = 8
        commitButton.cornerRadius = 5
        commitButton.onClick = { [weak self] in self?.onCommit?() }
        commitButton.setAccessibilityIdentifier("history.workingChanges.commitButton")
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        addSubview(commitButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("history.workingChangesRow")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WorkingChangesRowView is built in code") }

    private func applyState() {
        isHidden = !state.isVisible
        label.stringValue = state.summaryText
        label.font = TextLines.system(12 * min(1.15, max(0.95, scale)), weight: .medium)
        setAccessibilityLabel(state.summaryText)
        needsLayout = true
        needsDisplay = true
    }

    var headNodeCenterX: CGFloat {
        let path = GraphPath(
            spacing: GraphCell.laneSpacing * scale, offset: GraphCell.laneOffset * scale,
            height: bounds.height, style: GraphCell.lineStyle)
        return path.x(min(state.headLane, max(0, GraphCell.maximumLanes - 1))) + horizontalOffset
    }

    override func layout() {
        super.layout()
        let graphWidth = GraphCell.width(lastLane: max(0, laneCount - 1), scale: scale) + 2 * scale
        let buttonSize = commitButton.fittingSize
        let buttonX = max(graphWidth + 16, bounds.width - buttonSize.width - Metrics.trailingInset)
        commitButton.frame = NSRect(
            x: buttonX,
            y: ((bounds.height - buttonSize.height) / 2).rounded(),
            width: buttonSize.width,
            height: buttonSize.height)
        let labelX = max(headNodeCenterX + 12, graphWidth + horizontalOffset)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: labelX,
            y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(0, buttonX - labelX - 8),
            height: labelHeight)
    }

    override func draw(_: NSRect) {
        if state.isSelected {
            Theme.rowSelection.setFill()
        } else if hovering {
            Theme.control.withAlphaComponent(0.55).setFill()
        } else {
            Theme.window.setFill()
        }
        bounds.fill()

        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = HistoryTint.laneColors(dark: dark)
        let color = palette[abs(state.headColor) % max(1, palette.count)].cgColor
        let x = headNodeCenterX
        let middle = bounds.height / 2
        let radius = Metrics.nodeRadius * scale

        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(Metrics.nodeLineWidth * scale)
        context.setLineDash(phase: 0, lengths: Metrics.dashPattern)
        context.move(to: CGPoint(x: x, y: middle + radius))
        context.addLine(to: CGPoint(x: x, y: bounds.height))
        context.strokePath()

        let dot = CGRect(x: x - radius, y: middle - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(Theme.window.cgColor)
        context.fillEllipse(in: dot)
        context.strokeEllipse(in: dot)
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if commitButton.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }
        onSelect?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
