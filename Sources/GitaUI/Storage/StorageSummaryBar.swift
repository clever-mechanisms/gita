import AppKit
import GitaCore

@MainActor
final class StorageSummaryBar: NSView {
    private let report: RepositoryStorageReport
    private let presenter = StoragePresenter()
    private let cleanupButton: PartsButton

    init(report: RepositoryStorageReport, refresh: @escaping () -> Void, trash: @escaping () -> Void) {
        self.report = report
        let presenter = StoragePresenter()
        let cleanTitle = presenter.cleanButtonTitle(selectedPaths: [], in: report)
        let hasReclaimable =
            !report.isPartial
            && report.checkouts.contains { $0.heavyFolders.contains { $0.status == .reclaimable } }
        cleanupButton = StorageStyle.actionButton(
            cleanTitle, symbol: "trash", style: hasReclaimable ? .accent : .quiet,
            accessibility: String(localized: "Move Reclaimable to Trash"), onClick: trash)
        cleanupButton.isEnabled = hasReclaimable
        super.init(frame: .zero)

        let card = StorageStyle.card(cornerRadius: 10)
        Deck.pin(card, in: self)

        let refreshButton = StorageStyle.actionButton(
            String(localized: "Refresh"), symbol: "arrow.clockwise", style: .quiet, onClick: refresh)
        let header = StorageStyle.heroHeader(
            symbol: "internaldrive.fill",
            title: report.repositoryName,
            heroMetric: presenter.formatBytes(report.totalAllocatedBytes),
            subtitle: presenter.summarySubtitle(for: report),
            controls: [refreshButton, cleanupButton])
        let segments = presenter.summarySegments(for: report)
        let graph = StorageSegmentGraph(segments: segments)
        let legend = makeLegendRow(segments: segments)

        let stack = Deck.vstack([header, graph, legend], spacing: 12)
        Deck.pin(stack, in: card, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            graph.widthAnchor.constraint(equalTo: stack.widthAnchor),
            graph.heightAnchor.constraint(equalToConstant: 10),
            legend.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageSummaryBar is built in code") }

    func updateSelection(_ paths: Set<String>) {
        let title = presenter.cleanButtonTitle(selectedPaths: paths, in: report)
        let accessibility =
            paths.isEmpty
            ? String(localized: "Move Reclaimable to Trash")
            : String(localized: "Move Selected to Trash")
        cleanupButton.background = paths.isEmpty && cleanupButton.isEnabled ? .accent : .quiet
        StorageStyle.setButtonContent(cleanupButton, title: title, symbol: "trash", accessibility: accessibility)
    }

    private func makeLegendRow(segments: [StorageBarSegment]) -> NSView {
        let row = Deck.hstack([], spacing: 18)
        for segment in segments {
            let dot = FillView(color: StorageSegmentGraph.color(segment.colorRole))
            dot.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.setAccessibilityElement(false)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            let name = Deck.label(segment.label, font: Theme.captionEmphasis, color: Theme.text)
            let metrics = Deck.label(
                "\(segment.formattedBytes) (\(segment.percentText))",
                font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                color: Theme.secondaryText)
            let item = Deck.hstack([dot, name, metrics], spacing: 5)
            item.setVisibilityPriority(.detachOnlyIfNecessary, for: metrics)
            row.addArrangedSubview(item)
        }
        row.addArrangedSubview(Deck.spacer())
        return row
    }
}

private final class StorageSegmentGraph: NSView, NSViewToolTipOwner {
    private let segments: [StorageBarSegment]
    private var tips = [NSView.ToolTipTag: String]()
    private static let segmentGap: CGFloat = 2

    init(segments: [StorageBarSegment]) {
        self.segments = segments
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(segments.map(\.tooltip).joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageSegmentGraph is built in code") }

    static func color(_ role: StorageBarSegment.ColorRole) -> NSColor {
        switch role {
        case .gitStore: Theme.accent
        case .reclaimable: Theme.success
        case .workingTrees: Theme.merged
        }
    }

    private func rectangles(_ body: (StorageBarSegment, NSRect) -> Void) {
        let active = segments.filter { $0.fraction > 0 }
        guard !active.isEmpty, bounds.width > 0 else { return }
        let gapTotal = Self.segmentGap * CGFloat(max(0, active.count - 1))
        let usable = max(0, bounds.width - gapTotal)
        var x: CGFloat = 0
        for (index, segment) in active.enumerated() {
            let rawWidth = usable * segment.fraction
            let width = index == active.count - 1 ? max(0, bounds.width - x) : max(2, rawWidth)
            let rect = NSRect(x: x, y: 0, width: min(width, max(0, bounds.width - x)), height: bounds.height)
            body(segment, rect)
            x = rect.maxX + Self.segmentGap
        }
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        tips.removeAll()
        rectangles { segment, rect in tips[addToolTip(rect, owner: self, userData: nil)] = segment.tooltip }
    }

    func view(
        _: NSView, stringForToolTip tag: NSView.ToolTipTag, point _: NSPoint,
        userData _: UnsafeMutableRawPointer?
    ) -> String {
        tips[tag] ?? ""
    }

    override func draw(_: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        Theme.control.setFill()
        bounds.fill()
        rectangles { segment, rect in
            Self.color(segment.colorRole).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
