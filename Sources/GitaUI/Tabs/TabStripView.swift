import AppKit

/// Shows the tabs and group chips where `TabStripLayout` puts them. A tab or a group's chip dragged sideways moves
/// along the strip (a group with its tabs); the others make room.
@MainActor
final class TabStripView: NSView {
    enum Item {
        case chip(TabGroupChipView, TabGroup)
        case tab(NSView, group: TabGroup?)

        var view: NSView {
            switch self {
            case .chip(let chip, _): chip
            case .tab(let tab, _): tab
            }
        }
        var groupID: UUID? {
            switch self {
            case .chip(_, let group): group.id
            case .tab(_, let group): group?.id
            }
        }
    }
    /// What is being dragged: one tab, or a group's chip with the group's tabs.
    enum DragSubject {
        case tab(NSView)
        case group(UUID)
    }
    private struct Drag {
        var views: Set<ObjectIdentifier>
        var left: CGFloat
    }
    private var items: [Item] = []
    private var entries: [TabStripLayout.Entry] = []
    private var lines: [FillView] = []
    /// Where each shown item belongs, before a drag moves it.
    private var slots: [CGRect?] = []
    private var drag: Drag?
    var onLayoutWidth: (() -> CGFloat)?
    /// While dragging: the subject's left edge moved to `x`; the owner reorders and hands back new items.
    var onDrag: ((DragSubject, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var isDragging: Bool { drag != nil }
    override var isFlipped: Bool { true }
    private var stripHeight: CGFloat { Theme.tabHeight + 4 - 1 }

    func setItems(_ next: [Item]) {
        let views = next.map(\.view)
        for view in items.map(\.view) where !views.contains(where: { $0 === view }) { view.removeFromSuperview() }
        var added = false
        for view in views where view.superview !== self {
            addSubview(view)
            added = true
        }
        // New tabs go on top: lift the group lines back above them.
        if added { for line in lines { addSubview(line, positioned: .above, relativeTo: nil) } }
        items = next
        relayout()
    }
    /// The shown items in order with the places they belong in (not where a drag holds them).
    var layoutItems: [(Item, NSRect)] {
        zip(items, slots).compactMap { item, frame in frame.map { (item, $0) } }
    }
    func relayout(animated: Bool = false) {
        entries = items.map(Self.entry)
        let available = max(0, onLayoutWidth?() ?? bounds.width)
        let layout = TabStripLayout.slots(entries, available: available, height: stripHeight)
        slots = layout.frames
        for (item, frame) in zip(items, slots) { item.view.isHidden = frame == nil }
        setFrameSize(NSSize(width: layout.width, height: stripHeight))
        let frames = placedFrames()
        for (item, frame) in zip(items, frames) {
            guard let frame else { continue }
            if drag?.views.contains(ObjectIdentifier(item.view)) == true {
                item.view.frame = frame
            } else if animated, item.view.frame.size == frame.size {
                item.view.animator().frame = frame
            } else {
                item.view.frame = frame
            }
        }
        placeLines(TabStripLayout.lines(entries, frames: frames))
    }
    private static func entry(_ item: Item) -> TabStripLayout.Entry {
        switch item {
        case .chip(let chip, let group):
            TabStripLayout.Entry(
                kind: .chip(width: chip.preferredWidth), groupID: group.id, collapsed: group.collapsed,
                color: group.color)
        case .tab(_, let group):
            TabStripLayout.Entry(kind: .tab, groupID: group?.id, collapsed: group?.collapsed ?? false)
        }
    }
    /// Dragged views follow the pointer, keeping their places relative to one another; the others go to their slots.
    private func placedFrames() -> [CGRect?] {
        guard let drag else { return slots }
        let dragged = zip(items, slots).compactMap { item, frame in
            drag.views.contains(ObjectIdentifier(item.view)) ? frame?.minX : nil
        }
        guard let start = dragged.min() else { return slots }
        return zip(items, slots).map { item, frame in
            guard var frame, drag.views.contains(ObjectIdentifier(item.view)) else { return frame }
            frame.origin.x += drag.left - start
            return frame
        }
    }
    /// The group lines sit on top of the tabs, along the bottom edge.
    private func placeLines(_ spans: [TabStripLayout.Line]) {
        while lines.count < spans.count { lines.append(FillView(color: .clear)) }
        for (index, line) in lines.enumerated() {
            guard index < spans.count else {
                line.removeFromSuperview()
                continue
            }
            let span = spans[index]
            line.color = span.color.color
            line.frame = NSRect(
                x: span.minX, y: stripHeight - TabStripLayout.lineHeight, width: span.maxX - span.minX,
                height: TabStripLayout.lineHeight)
            if line.superview !== self { addSubview(line, positioned: .above, relativeTo: nil) }
        }
        lines.removeSubrange(spans.count...)
    }

    // MARK: Dragging

    /// Follows a press on a tab or chip until the button is released. Returns false when the press was a click (the
    /// caller then handles it as one).
    func trackDrag(_ subject: DragSubject, from event: NSEvent) -> Bool {
        guard let window else { return false }
        var tracker = DragTracker(start: convert(event.locationInWindow, from: nil).x)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let x = convert(next.locationInWindow, from: nil).x
            switch tracker.move(to: x, begin: { beginDrag(subject) }) {
            case .pending: continue
            case .cancelled: return false
            case .moved(let left): moveDrag(subject, to: left)
            }
            _ = autoscroll(with: next)
        }
        guard tracker.didDrag else { return false }
        endDrag()
        return true
    }
    /// Lifts the dragged views above the others and returns where the subject starts.
    func beginDrag(_ subject: DragSubject) -> CGFloat? {
        let views = draggedViews(subject)
        guard !views.isEmpty else { return nil }
        let frames = Dictionary(zip(items.map { ObjectIdentifier($0.view) }, slots)) { first, _ in first }
        let left = views.compactMap { frames[ObjectIdentifier($0)]??.minX }.min() ?? 0
        drag = Drag(views: Set(views.map(ObjectIdentifier.init)), left: left)
        for view in views { addSubview(view, positioned: .above, relativeTo: nil) }
        for line in lines { addSubview(line, positioned: .above, relativeTo: nil) }
        return left
    }
    /// Holds the dragged views with their left edge at `left` (kept on the strip) and lets the owner reorder.
    func moveDrag(_ subject: DragSubject, to left: CGFloat) {
        guard let views = drag?.views else { return }
        let dragged = layoutItems.filter { views.contains(ObjectIdentifier($0.0.view)) }.map(\.1)
        let span = (dragged.map(\.maxX).max() ?? 0) - (dragged.map(\.minX).min() ?? 0)
        let clamped = DragTracker.clamp(left, span: span, width: bounds.width)
        drag?.left = clamped
        relayout(animated: true)
        onDrag?(subject, clamped)
    }
    /// The dragged views settle into their new places.
    func endDrag() {
        drag = nil
        relayout(animated: true)
        onDragEnd?()
    }
    private func draggedViews(_ subject: DragSubject) -> [NSView] {
        switch subject {
        case .tab(let view): return items.contains { $0.view === view } ? [view] : []
        case .group(let id):
            return zip(items, slots).filter { $0.0.groupID == id && $0.1 != nil }.map(\.0.view)
        }
    }
}
