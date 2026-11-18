import AppKit
import GitaCore

/// The history scenes: the whole history searched and zoomed (Welcome), and one per History option.
extension SetupScenes {
    static let searchQuery = "search"
    private static let zoomedScale: CGFloat = 1.3
    private static let barHeight: CGFloat = 22

    // MARK: Welcome: every branch at once

    /// How far the search is typed at `frame`, 0…1: typed in on step 1, erased on step 2.
    static func searchAmount(_ frame: Frame) -> CGFloat {
        switch frame.step {
        case 1: frame.progress
        case 2: 1 - frame.progress
        default: 0
        }
    }
    /// The zoom at `frame`: in on step 2, back out on step 0.
    static func zoomScale(_ frame: Frame) -> CGFloat {
        switch frame.step {
        case 2: 1 + (zoomedScale - 1) * frame.progress
        case 0: zoomedScale - (zoomedScale - 1) * frame.progress
        default: 1
        }
    }
    /// The sample rows whose subject the search matches.
    static func matches(_ query: String) -> Set<Int> {
        guard !query.isEmpty else { return [] }
        let rows = sampleHistory.enumerated().filter {
            $0.element.subject.localizedCaseInsensitiveContains(query)
        }
        return Set(rows.map(\.offset))
    }

    /// The search field and the zoom over the history: the query types in and dims what it does not match, then the
    /// history zooms in and back out.
    static func drawHistory(_ frame: Frame) {
        let rect = frame.rect
        let typed = searchAmount(frame)
        let query = String(searchQuery.prefix(Int((typed * CGFloat(searchQuery.count)).rounded())))
        let scale = zoomScale(frame)
        let zoom = String(localized: "\(Int((scale * 100).rounded()))%")
        let zoomWidth = pillWidth(zoom, image: false)
        searchField(query, in: NSRect(x: rect.minX, y: rect.minY, width: rect.width - zoomWidth - 8, height: barHeight))
        pill(zoom, at: NSPoint(x: rect.maxX - zoomWidth, y: rect.minY + 2), color: Theme.accentText)
        let graph = NSRect(x: rect.minX, y: rect.minY + barHeight + 8, width: rect.width, height: rect.height - 30)
        let found = matches(searchQuery)
        if typed > 0.01 {
            let rowHeight = SceneGraph.rowHeight * scale
            Theme.accent.withAlphaComponent(0.14 * typed).setFill()
            for row in found {
                NSBezierPath(
                    roundedRect: NSRect(
                        x: graph.minX, y: graph.minY + rowHeight * CGFloat(row), width: graph.width, height: rowHeight),
                    xRadius: 4, yRadius: 4
                ).fill()
            }
        }
        sampleGraph(in: graph, scale: scale) { found.contains($0) ? 1 : 1 - 0.65 * typed }
    }

    private static func searchField(_ query: String, in rect: NSRect) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        Theme.window.setFill()
        shape.fill()
        Theme.separator.setStroke()
        shape.stroke()
        Deck.symbol("magnifyingglass", size: 10, color: Theme.secondaryText)?.draw(
            in: NSRect(x: rect.minX + 7, y: rect.minY + 5, width: 12, height: 12), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
        let empty = query.isEmpty
        text(
            empty ? String(localized: "Search the history") : query, at: NSPoint(x: rect.minX + 24, y: rect.minY + 3),
            font: Theme.body, color: empty ? Theme.secondaryText : Theme.text, width: rect.width - 30)
    }

    // MARK: History options

    /// The commit details under the history, sliding in and out with the selected commit's message and files.
    static func drawDetails(_ frame: Frame) {
        let rect = frame.rect
        let open = amount(frame)
        stateTag(isOn(frame), in: rect)
        let pane = rect.height * 0.5 * open
        let history = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - pane)
        Theme.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: history.minX, y: history.minY, width: history.width - 44, height: 22), xRadius: 4,
            yRadius: 4
        ).fill()
        sampleGraph(in: history, subjectsEnd: rect.maxX - 44)
        guard open > 0.01 else { return }
        let top = rect.maxY - pane
        Theme.separator.withAlphaComponent(open).setFill()
        NSRect(x: rect.minX, y: top, width: rect.width, height: 1).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: rect.minX, y: top + 1, width: rect.width, height: pane)).addClip()
        let commit = sampleHistory[0]
        text(
            commit.subject, at: NSPoint(x: rect.minX + 4, y: top + 6), font: Theme.bodyEmphasis, color: Theme.text,
            alpha: open)
        text(
            "3f9c2a1 · Ana · " + String(localized: "2 hours ago"), at: NSPoint(x: rect.minX + 4, y: top + 22),
            font: Theme.mono,
            color: Theme.secondaryText, alpha: open)
        let files: [(String, String, NSColor)] = [
            ("M", "Sidebar.swift  +12 −3", Theme.running), ("A", "TabShortcuts.swift  +48", Theme.success),
        ]
        for (index, file) in files.enumerated() {
            let y = top + 40 + CGFloat(index) * 16
            text(file.0, at: NSPoint(x: rect.minX + 4, y: y), font: Theme.mono, color: file.2, alpha: open)
            text(file.1, at: NSPoint(x: rect.minX + 18, y: y), font: Theme.mono, color: Theme.text, alpha: open)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The history at the drafted zoom: taller rows and larger text, fewer rows in view.
    static func drawZoom(_ frame: Frame) {
        let scale = CGFloat(HistoryZoom.bounded(frame.choices.historyZoomPercent)) / 100
        sampleGraph(in: frame.rect, scale: scale)
    }

    /// Collapse merged commits or squash merges as merges, played off and on.
    static func drawMerge(_ frame: Frame) {
        let kind: MergeIllustrationView.Kind = frame.scene == .collapse ? .collapse : .squash
        MergeIllustrationScenes.scene(kind, isOn: isOn(frame), amount: amount(frame), in: frame.rect)
    }
}
