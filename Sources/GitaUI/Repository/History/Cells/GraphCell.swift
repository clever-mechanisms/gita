import AppKit
import GitaCore

/// Lanes 16 pt apart; every commit is a hollow node drawn in its lane colour. A merge's node is the avatar of who
/// merged it, ringed in the lane colour. The lines come from `GraphPath`; this view only strokes them.
///
/// At most `maximumLanes` lanes are drawn (`GraphOverflow`): a row with more ends its lines at the edge, shows how
/// many lanes go past it, and draws a commit whose own lane is past it at the edge.
@MainActor
final class GraphCell: NSView {
    typealias LineStyle = GraphLineStyle
    static let laneSpacing: CGFloat = 16
    static let laneOffset: CGFloat = 10
    /// Deep in a history with many long-lived branches the graph grows to hundreds of lanes (React: ~300, which
    /// would make the subject column 4 800 pt wide); past this many, lanes are not drawn.
    static let maximumLanes = 40
    private enum Metrics {
        static let edgeMargin: CGFloat = 4
        static let minimumLineWidth: CGFloat = 1.5
        static let lineWidth: CGFloat = 2
        static let nodeRadius: CGFloat = 4
        static let nodeLineWidth: CGFloat = 2
        static let headInset: CGFloat = 2.5
        static let avatarSide: CGFloat = 13
        static let avatarRing: CGFloat = 1.5
        /// Room for the count of lanes past the edge ("+262"), and its type size.
        static let overflowLabel: CGFloat = 34
        static let overflowFont: CGFloat = 9
        static let chevron: CGFloat = 3
    }
    /// The width of a graph whose last lane is `lastLane`; past `maximumLanes`, the edge and its count.
    static func width(lastLane: Int, scale: CGFloat) -> CGFloat {
        guard lastLane >= maximumLanes else {
            return (laneOffset * 2 + Metrics.edgeMargin + CGFloat(lastLane) * laneSpacing) * scale
        }
        return (laneOffset * 2 + Metrics.edgeMargin + CGFloat(maximumLanes) * laneSpacing + Metrics.overflowLabel)
            * scale
    }
    private static var cachedStyle: LineStyle?
    static var lineStyle: LineStyle {
        if let cachedStyle { return cachedStyle }
        let style = LineStyle(rawValue: Preference.graphLines.string()) ?? .rounded
        cachedStyle = style
        return style
    }
    static let lineStyleChanged = Notification.Name("dev.clevermechanisms.Gita.graphLinesChanged")
    static func setLineStyle(_ style: LineStyle) {
        guard style != lineStyle else { return }
        Preference.graphLines.set(style.rawValue)
        cachedStyle = style
        NotificationCenter.default.post(name: lineStyleChanged, object: nil)
    }

    var row: GraphRow? { didSet { needsDisplay = true } }
    /// The row above: a lane it shifts over is drawn across the boundary between the two rows, so this row draws the
    /// shift's lower half.
    var previous: GraphRow? { didSet { needsDisplay = true } }
    /// The row below: a lane that moves left into a lane which then moves right there goes straight to where that
    /// lane ends up, instead of reaching its old place after it left.
    var next: GraphRow? { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    var isMerge = false
    var isHead = false
    var merge: MergeFlair?
    /// Below 1 the node fades (another author's commit while one is highlighted); the lines through it do not.
    var nodeAlpha: CGFloat = 1 { didSet { if nodeAlpha != oldValue { needsDisplay = true } } }
    /// Lanes drawn at most (`maximumLanes`; a test draws without the limit to compare).
    var laneLimit = GraphCell.maximumLanes { didSet { needsDisplay = true } }
    /// The lanes of this row past `laneLimit`, if any.
    var overflow: GraphOverflow? { row.flatMap { GraphOverflow(row: $0, limit: laneLimit) } }
    override var isFlipped: Bool { true }

    /// Lane colours resolved once per appearance and commit colour (not once per edge).
    private static var palettes: [String: [CGColor]] = [:]
    private static func palette(dark: Bool) -> [CGColor] {
        let key = "\(dark) \(HistoryTint.stored(.commits).rawValue)"
        if let palette = palettes[key] { return palette }
        var palette: [CGColor] = []
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing())
            .performAsCurrentDrawingAppearance { palette = HistoryTint.laneColors(dark: dark).map(\.cgColor) }
        palettes[key] = palette
        return palette
    }

    /// The geometry of this cell's lines at its current size and scale.
    var path: GraphPath {
        GraphPath(
            spacing: Self.laneSpacing * scale, offset: Self.laneOffset * scale, height: bounds.height,
            style: Self.lineStyle)
    }

    override func draw(_: NSRect) {
        guard let row, let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = Self.palette(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let path = path
        let overflow = overflow
        // Past the limit, lines end half a lane after the last lane drawn.
        let edge = overflow.map { _ in path.x(laneLimit) - path.spacing / 2 } ?? bounds.maxX
        context.setLineWidth(max(Metrics.minimumLineWidth, Metrics.lineWidth * scale))
        context.setLineCap(.round)
        context.saveGState()
        context.clip(to: CGRect(x: bounds.minX, y: bounds.minY, width: edge - bounds.minX, height: bounds.height))
        context.setLineJoin(.round)
        let strokes =
            if overflow == nil {
                path.strokes(row: row, previous: previous, next: next)
            } else {
                // Only the lines that reach the lanes drawn: deep in a wide history most of them do not.
                path.strokes(
                    row: GraphOverflow.visible(row, limit: laneLimit),
                    previous: previous.map { GraphOverflow.visible($0, limit: laneLimit) },
                    next: next.map { GraphOverflow.visible($0, limit: laneLimit) })
            }
        // A wide history passes many lanes straight through each row. Those lines never cross and their round caps
        // fall outside the row, so they are filled as rectangles, one fill per colour (stroking them is what costs
        // most in a wide graph); then every turning line is stroked in order, so merge lines still cross over them.
        let width = max(Metrics.minimumLineWidth, Metrics.lineWidth * scale)
        var straight: [Int: [CGRect]] = [:]
        for stroke in strokes {
            guard let (top, bottom) = Self.straightLine(stroke), top.x - width / 2 < edge else { continue }
            straight[abs(stroke.color) % palette.count, default: []].append(
                CGRect(
                    x: top.x - width / 2, y: min(top.y, bottom.y), width: width, height: abs(bottom.y - top.y)))
        }
        for (color, rects) in straight.sorted(by: { $0.key < $1.key }) {
            context.setFillColor(palette[color])
            context.fill(rects)
        }
        for stroke in strokes where Self.straightLine(stroke) == nil {
            for element in stroke.elements { Self.add(element, to: context) }
            context.setStrokeColor(palette[abs(stroke.color) % palette.count])
            context.strokePath()
        }
        context.restoreGState()
        let color = palette[abs(row.color) % palette.count]
        guard let overflow else {
            drawNode(row, x: path.x(row.lane), color: color, in: context)
            return
        }
        // The commit's own lane past the edge: its node sits at the edge, where the chevron is otherwise.
        let marker = path.x(laneLimit)
        if overflow.nodeHidden {
            drawNode(row, x: marker, color: color, in: context)
        } else {
            drawNode(row, x: path.x(row.lane), color: color, in: context)
            drawChevron(at: marker, in: context)
        }
        context.setAlpha(1)
        drawCount(overflow.hidden, after: marker + Metrics.nodeRadius * scale)
    }

    /// "›" at the edge: lanes go on past it.
    private func drawChevron(at x: CGFloat, in context: CGContext) {
        let middle = bounds.height / 2
        let size = Metrics.chevron * scale
        context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        context.setLineWidth(max(Metrics.minimumLineWidth, Metrics.lineWidth * scale) * 0.75)
        context.move(to: CGPoint(x: x - size / 2, y: middle - size))
        context.addLine(to: CGPoint(x: x + size / 2, y: middle))
        context.addLine(to: CGPoint(x: x - size / 2, y: middle + size))
        context.strokePath()
    }

    /// "+N": how many lanes of this row are past the edge.
    private func drawCount(_ count: Int, after x: CGFloat) {
        let text = NSAttributedString(
            string: "+" + count.formatted(),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: Metrics.overflowFont * scale, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let size = text.size()
        text.draw(at: NSPoint(x: x + 4 * scale, y: ((bounds.height - size.height) / 2).rounded()))
    }

    /// The ends of a stroke that runs straight down its lane.
    private static func straightLine(_ stroke: GraphPath.Stroke) -> (CGPoint, CGPoint)? {
        guard stroke.elements.count == 2, case .move(let top) = stroke.elements[0],
            case .line(let bottom) = stroke.elements[1], top.x == bottom.x
        else { return nil }
        return (top, bottom)
    }

    static func add(_ element: GraphPath.Element, to context: CGContext) {
        switch element {
        case .move(let point): context.move(to: point)
        case .line(let point): context.addLine(to: point)
        case .arc(let corner, let next, let radius):
            context.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        case .curve(let point, let control1, let control2):
            context.addCurve(to: point, control1: control1, control2: control2)
        }
    }

    private func drawNode(_ row: GraphRow, x: CGFloat, color: CGColor, in context: CGContext) {
        let middle = bounds.height / 2
        if isMerge, let merge {
            drawMergeNode(merge, center: CGPoint(x: x, y: middle), lane: row.color, color: color, in: context)
            return
        }
        let radius = Metrics.nodeRadius * scale
        let dot = CGRect(x: x - radius, y: middle - radius, width: radius * 2, height: radius * 2)
        context.setFillColor(Theme.window.cgColor)
        context.fillEllipse(in: dot)
        context.setAlpha(nodeAlpha)
        context.setStrokeColor(color)
        context.setLineWidth(Metrics.nodeLineWidth * scale)
        context.strokeEllipse(in: dot)
        if isHead || isMerge {
            context.setFillColor(color)
            context.fillEllipse(in: dot.insetBy(dx: Metrics.headInset * scale, dy: Metrics.headInset * scale))
        }
    }

    /// The merger's avatar, ringed in the lane colour.
    private func drawMergeNode(_ merge: MergeFlair, center: CGPoint, lane: Int, color: CGColor, in context: CGContext) {
        let side = (Metrics.avatarSide * scale).rounded()
        let ring = Metrics.avatarRing * scale
        let avatar = CGRect(
            x: (center.x - side / 2).rounded(), y: (center.y - side / 2).rounded(), width: side, height: side)
        if nodeAlpha < 1 {
            // Cover the lines under the node first, so the faded avatar does not show them through.
            context.setFillColor(Theme.window.cgColor)
            context.fillEllipse(in: avatar.insetBy(dx: -ring, dy: -ring))
            context.setAlpha(nodeAlpha)
        }
        context.setFillColor(color)
        context.fillEllipse(in: avatar.insetBy(dx: -ring, dy: -ring))
        AvatarPainter.draw(merge.mergedBy, email: merge.email, in: avatar, lane: lane)
    }
}
