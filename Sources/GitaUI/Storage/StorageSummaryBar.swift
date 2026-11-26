import AppKit
import GitaCore

@MainActor
final class StorageSummaryBar: NSView {
    private let cleanupButton: ActionButton

    func updateSelection(_ paths: Set<String>) {
        cleanupButton.title =
            paths.isEmpty
            ? String(localized: "Move Reclaimable to Trash…") : String(localized: "Move Selected to Trash…")
    }

    init(report: RepositoryStorageReport, refresh: @escaping () -> Void, trash: @escaping () -> Void) {
        cleanupButton = ActionButton(title: String(localized: "Move Reclaimable to Trash…"), onPress: trash)
        super.init(frame: .zero)
        let presenter = StoragePresenter()
        let segments = presenter.summarySegments(for: report)
        let graph = StorageSegmentGraph(segments: segments)
        let heading = Deck.label(report.repositoryName, font: Theme.title)
        let size = Deck.label(presenter.formatBytes(report.totalAllocatedBytes), font: Theme.mono)
        let callout = Self.badge(String(localized: "\(presenter.formatBytes(report.reclaimableBytes)) reclaimable"))
        cleanupButton.isEnabled =
            !report.isPartial
            && report.checkouts.contains { checkout in
                checkout.heavyFolders.contains { $0.status == .reclaimable }
            }
        let toolbar = Deck.hstack([
            heading, size, Deck.spacer(), callout,
            ActionButton(title: String(localized: "Refresh"), onPress: refresh), cleanupButton,
        ])
        let legend = Deck.hstack(
            segments.map { segment in
                let dot = FillView(color: StorageSegmentGraph.color(segment.colorRole))
                dot.cornerRadius = 4
                dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
                let label = Deck.label(
                    segment.tooltip, font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    color: Theme.secondaryText)
                return Deck.hstack([dot, label], spacing: 4)
            }, spacing: 16)
        let stack = Deck.vstack([toolbar, graph, legend], spacing: 9)
        Deck.pin(stack, in: self)
        toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    static func badge(
        _ text: String, fill: NSColor = Theme.success.withAlphaComponent(0.13), monospacedDigits: Bool = true
    ) -> NSView {
        let badge = FillView(color: fill)
        badge.cornerRadius = 7
        let font =
            monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) : Theme.captionEmphasis
        Deck.pin(
            Deck.label(text, font: font, color: Theme.text), in: badge,
            insets: NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7))
        return badge
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageSummaryBar is built in code") }
}

private final class StorageSegmentGraph: NSView, NSViewToolTipOwner {
    private let segments: [StorageBarSegment]
    private var tips = [NSView.ToolTipTag: String]()

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
        var x: CGFloat = 0
        for segment in segments where segment.fraction > 0 {
            let rect = NSRect(x: x, y: 0, width: bounds.width * segment.fraction, height: bounds.height)
            body(segment, rect)
            x = rect.maxX
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
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).addClip()
        Theme.control.setFill()
        bounds.fill()
        rectangles { segment, rect in
            Self.color(segment.colorRole).setFill()
            rect.fill()
        }
    }
}
