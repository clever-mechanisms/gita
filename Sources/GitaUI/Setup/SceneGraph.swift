import AppKit
import GitaCore

/// A small, fictional history drawn the way the history list draws a real one: lanes and colours from `GraphLayout`,
/// lines from `GraphPath` in the chosen line style, hollow nodes with the head's and merges' filled in. One history can
/// also be drawn part way into another: a commit, branch label or subject in both slides to its new place, the rest
/// fades, and the lines cross-fade. Drawing only; nothing is read. A flipped context (y down) is assumed.
@MainActor
enum SceneGraph {
    /// A commit of a fictional history, newest first. A parent missing from the history is older history: the line
    /// runs on out of the last row.
    struct Commit: Equatable {
        var id: String
        var subject: String
        var parents: [String] = []
        /// Branch names on it.
        var labels: [String] = []
        /// The checked-out commit: its node is filled and its subject bold.
        var isHead = false
    }

    static let rowHeight: CGFloat = 22
    private static let nodeRadius: CGFloat = 4
    private static let headInset: CGFloat = 2.5
    private static let lineWidth: CGFloat = 2
    /// Where the labels and subjects start, past the third lane.
    static var textX: CGFloat { GraphCell.laneOffset + 2 * GraphCell.laneSpacing + 10 }

    /// Where a history's pieces sit in a rect: what `draw` strokes and fills.
    struct Layout {
        struct Node {
            var id: String
            var row: Int
            var center: NSPoint
            var color: NSColor
            /// 1 for the head and merges (filled), 0 for the rest.
            var fill: CGFloat
        }
        struct Label {
            var name: String
            var row: Int
            var origin: NSPoint
            var color: NSColor
        }
        struct Subject {
            var id: String
            var row: Int
            var text: String
            var origin: NSPoint
            /// 1 bold (the head), 0 regular.
            var emphasis: CGFloat
        }
        var rect: NSRect
        var rowHeight: CGFloat
        var rows: [GraphRow]
        var nodes: [Node] = []
        var labels: [Label] = []
        var subjects: [Subject] = []
        var subjectsEnd: CGFloat
    }

    /// `commits` laid out from the top of `rect`; subjects end at `subjectsEnd` (the rect's right edge by default).
    static func layout(
        _ commits: [Commit], in rect: NSRect, rowHeight: CGFloat = rowHeight, subjectsEnd: CGFloat? = nil
    ) -> Layout {
        let rows = GraphLayout.build(
            commits: commits.map {
                GitCommit(id: $0.id, parents: $0.parents, subject: $0.subject, author: "", date: .distantPast)
            })
        let path = graphPath(rect, rowHeight: rowHeight)
        var layout = Layout(rect: rect, rowHeight: rowHeight, rows: rows, subjectsEnd: subjectsEnd ?? rect.maxX)
        for (index, (commit, row)) in zip(commits, rows).enumerated() {
            let center = NSPoint(x: path.x(row.lane), y: rect.minY + rowHeight * (CGFloat(index) + 0.5))
            let color = SetupScenes.lane(row.color)
            layout.nodes.append(
                .init(
                    id: commit.id, row: index, center: center, color: color,
                    fill: commit.isHead || commit.parents.count > 1 ? 1 : 0))
            var x = rect.minX + textX
            for name in commit.labels {
                layout.labels.append(
                    .init(name: name, row: index, origin: NSPoint(x: x, y: center.y - 9), color: color))
                x += SetupScenes.pillWidth(name, image: false) + 6
            }
            layout.subjects.append(
                .init(
                    id: commit.id, row: index, text: commit.subject, origin: NSPoint(x: x, y: center.y - 8),
                    emphasis: commit.isHead ? 1 : 0))
        }
        return layout
    }

    /// `layout` with each row at its own opacity, so a search can dim the rows it does not match.
    static func draw(_ layout: Layout, alpha: (Int) -> CGFloat = { _ in 1 }) {
        lines(layout) { alpha($0) }
        for node in layout.nodes { draw(node, alpha: alpha(node.row)) }
        for label in layout.labels { draw(label, alpha: alpha(label.row)) }
        for subject in layout.subjects { draw(subject, alpha: alpha(subject.row), end: layout.subjectsEnd) }
    }

    /// `old` turned `amount` (0…1) of the way into `new`: what both have slides, the rest fades out or in. The lines
    /// cross-fade, unless they are the same.
    static func draw(from old: Layout, to new: Layout, amount: CGFloat) {
        if old.rows == new.rows {
            lines(new) { _ in 1 }
        } else {
            lines(old) { _ in 1 - amount }
            lines(new) { _ in amount }
        }
        morph(old.nodes, new.nodes, key: \.id, amount: amount) { node, alpha in
            draw(node, alpha: alpha)
        } blend: {
            var node = $1
            node.center = mix($0.center, $1.center, amount)
            node.color = mix($0.color, $1.color, amount)
            node.fill = $0.fill + ($1.fill - $0.fill) * amount
            return node
        }
        morph(old.labels, new.labels, key: \.name, amount: amount) { label, alpha in
            draw(label, alpha: alpha)
        } blend: {
            var label = $1
            label.origin = mix($0.origin, $1.origin, amount)
            label.color = mix($0.color, $1.color, amount)
            return label
        }
        morph(old.subjects, new.subjects, key: \.id, amount: amount) { subject, alpha in
            draw(subject, alpha: alpha, end: new.subjectsEnd)
        } blend: {
            var subject = $1
            subject.origin = mix($0.origin, $1.origin, amount)
            subject.emphasis = $0.emphasis + ($1.emphasis - $0.emphasis) * amount
            return subject
        }
    }

    /// Draws what only `old` has fading out, what only `new` has fading in, and what both have blended.
    private static func morph<Item>(
        _ old: [Item], _ new: [Item], key: (Item) -> String, amount: CGFloat, draw: (Item, CGFloat) -> Void,
        blend: (Item, Item) -> Item
    ) {
        let kept = Set(new.map(key))
        for item in old where !kept.contains(key(item)) { draw(item, 1 - amount) }
        let before = Dictionary(old.map { (key($0), $0) }) { first, _ in first }
        for item in new {
            if let start = before[key(item)] { draw(blend(start, item), 1) } else { draw(item, amount) }
        }
    }

    // MARK: Pieces

    private static func graphPath(_ rect: NSRect, rowHeight: CGFloat) -> GraphPath {
        GraphPath(
            spacing: GraphCell.laneSpacing, offset: rect.minX + GraphCell.laneOffset, height: rowHeight,
            style: GraphCell.lineStyle)
    }

    /// Every row's lines, as `GraphCell` strokes them, at the row's opacity.
    private static func lines(_ layout: Layout, alpha: (Int) -> CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let path = graphPath(layout.rect, rowHeight: layout.rowHeight)
        let rows = layout.rows
        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (index, row) in rows.enumerated() where alpha(index) > 0.01 {
            context.saveGState()
            context.translateBy(x: 0, y: layout.rect.minY + layout.rowHeight * CGFloat(index))
            let strokes = path.strokes(
                row: row, previous: index > 0 ? rows[index - 1] : nil,
                next: index + 1 < rows.count ? rows[index + 1] : nil)
            for stroke in strokes {
                for element in stroke.elements { GraphCell.add(element, to: context) }
                context.setStrokeColor(SetupScenes.lane(stroke.color).withAlphaComponent(alpha(index)).cgColor)
                context.strokePath()
            }
            context.restoreGState()
        }
        context.restoreGState()
    }

    private static func draw(_ node: Layout.Node, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        let rect = NSRect(
            x: node.center.x - nodeRadius, y: node.center.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2)
        let dot = NSBezierPath(ovalIn: rect)
        Theme.window.withAlphaComponent(alpha).setFill()
        dot.fill()
        node.color.withAlphaComponent(alpha).setStroke()
        dot.lineWidth = lineWidth
        dot.stroke()
        guard node.fill > 0.01 else { return }
        node.color.withAlphaComponent(alpha * node.fill).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: headInset, dy: headInset)).fill()
    }

    private static func draw(_ label: Layout.Label, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        SetupScenes.pill(label.name, at: label.origin, color: label.color, alpha: alpha)
    }

    /// The subject; while its weight changes, the bold one fades in over the regular one.
    private static func draw(_ subject: Layout.Subject, alpha: CGFloat, end: CGFloat) {
        guard alpha > 0.01 else { return }
        let width = max(0, end - subject.origin.x)
        for (font, share) in [(Theme.body, 1 - subject.emphasis), (Theme.bodyEmphasis, subject.emphasis)]
        where share > 0.01 {
            SetupScenes.text(
                subject.text, at: subject.origin, font: font, color: Theme.text, alpha: alpha * share, width: width)
        }
    }

    private static func mix(_ a: NSPoint, _ b: NSPoint, _ amount: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
    }
    private static func mix(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
        a == b ? b : a.blended(withFraction: amount, of: b) ?? b
    }
}
