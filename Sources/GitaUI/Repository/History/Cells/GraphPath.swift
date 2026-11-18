import CoreGraphics
import GitaCore

/// Settings › Git › Graph lines (`Preference.graphLines`): the corners of a lane change.
enum GraphLineStyle: String, CaseIterable, Sendable {
    case rounded, angled
}

/// The lines of one history row as path elements, without a view: a lane change runs only vertically and
/// horizontally, so every line leaves and enters a row vertically and joins the next row seamlessly; the styles differ
/// only in the corners (rounded arcs or 45° cuts). A merge line crosses at the node's centre line; a lane moving right
/// bends above it; a lane moving left, and a commit's line to a lane on its left, bend across the boundary with the
/// next row.
struct GraphPath {
    enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        /// An arc tangent to the line into `corner` and the line from `corner` to `next`.
        case arc(corner: CGPoint, next: CGPoint, radius: CGFloat)
        case curve(CGPoint, control1: CGPoint, control2: CGPoint)
    }
    /// One stroke in one lane colour (`color` indexes the palette, modulo its size).
    struct Stroke: Equatable {
        var elements: [Element]
        var color: Int
    }

    /// Lane pitch and the first lane's centre, scaled.
    let spacing: CGFloat
    let offset: CGFloat
    /// The row's height; commit nodes sit on its centre line.
    let height: CGFloat
    let style: GraphLineStyle
    private var middle: CGFloat { height / 2 }

    /// Corners of a lane change across several lanes, and its bends, in fractions of the row height.
    private static let wideCornerRadius: CGFloat = 0.3
    private static let shiftStraight: CGFloat = 0.25
    private static let angledStraight: CGFloat = 0.2
    private static let cornerRadius: CGFloat = 0.6
    /// Below this the corner is drawn square.
    private static let minimumRadius: CGFloat = 0.5
    /// Shifts wider than this many lanes run along the boundary.
    private static let wideShift: CGFloat = 1.5

    func x(_ lane: Int) -> CGFloat { offset + CGFloat(lane) * spacing }

    /// Drawn across the boundary below its row, after the commit: a lane moving left (closing the gap the commit's
    /// own lane leaves) and the commit's line to a lane on its left (a branch's first commit joining its parent's
    /// line). A lane moving right makes room for a line the commit opens, so it moves in the top half, before the
    /// commit line (`rises`); a merge line to the right keeps its corner at the commit line.
    static func crossesBoundary(_ edge: GraphEdge) -> Bool { edge.to < edge.from }
    static func rises(_ edge: GraphEdge, in row: GraphRow) -> Bool { edge.to > edge.from && edge.from != row.lane }
    /// Where a boundary-crossing edge ends: its lane, or where the row below (`next`) moves that lane on to.
    static func target(of edge: GraphEdge, next: GraphRow?) -> Int {
        guard let next else { return edge.to }
        return next.outgoing.first { rises($0, in: next) && $0.from == edge.to }?.to ?? edge.to
    }

    /// Every stroke of `row`: lanes the row above shifted over (their lower half), lanes moving right, the lines into
    /// the commit and the lines out of it.
    func strokes(row: GraphRow, previous: GraphRow?, next: GraphRow?) -> [Stroke] {
        let arriving = previous.map { above in above.outgoing.filter(Self.crossesBoundary) } ?? []
        var strokes = arriving.map { edge in
            stroke(edge.color) { $0.shift(from: x(edge.from), to: x(Self.target(of: edge, next: row)), top: -middle) }
        }
        // A lane reached only by such a shift has no straight top half (one reached by the commit above as well does).
        let shiftedOnly = Set(arriving.map(\.to)).subtracting(
            previous?.outgoing.filter { !arriving.contains($0) }.map(\.to) ?? [])
        // Lanes moving right: the bend in the top half, so they are clear before the commit's new line comes across.
        // One reached only by a shift from the row above already arrived at its new place (`target`): straight down.
        let rising = row.outgoing.filter { Self.rises($0, in: row) && !shiftedOnly.contains($0.from) }
        let risen = Set(rising.map(\.from))
        strokes += rising.map { edge in
            stroke(edge.color) {
                $0.bend(from: CGPoint(x: x(edge.from), y: 0), to: CGPoint(x: x(edge.to), y: middle))
                $0.add(.line(CGPoint(x: x(edge.to), y: height)))
            }
        }
        for edge in row.incoming where !shiftedOnly.contains(edge.to) && !risen.contains(edge.to) {
            strokes.append(stroke(edge.color) { $0.incoming(edge) })
        }
        for edge in row.outgoing where !(Self.rises(edge, in: row) && risen.contains(edge.from)) {
            strokes.append(stroke(edge.color) { $0.outgoing(edge, in: row, next: next) })
        }
        return strokes
    }

    private func stroke(_ color: Int, _ build: (inout Builder) -> Void) -> Stroke {
        var builder = Builder(path: self)
        build(&builder)
        return Stroke(elements: builder.elements, color: color)
    }

    /// Accumulates one stroke's elements.
    private struct Builder {
        let path: GraphPath
        var elements: [Element] = []
        private var height: CGFloat { path.height }
        private var rounded: Bool { path.style == .rounded }

        mutating func add(_ element: Element) { elements.append(element) }

        /// A corner at `corner` between the line from `previous` and the line to `next`.
        mutating func turn(at corner: CGPoint, from previous: CGPoint, to next: CGPoint, radius: CGFloat) {
            let radius = min(radius, corner.distance(to: previous), next.distance(to: corner))
            guard radius > GraphPath.minimumRadius else {
                add(.line(corner))
                return
            }
            guard !rounded else {
                add(.arc(corner: corner, next: next, radius: radius))
                return
            }
            add(.line(corner.moved(toward: previous, by: radius)))
            add(.line(corner.moved(toward: next, by: radius)))
        }

        /// A lane passing through moves over across the boundary between two rows: straight down past the commit
        /// line, the bend from a quarter row above the boundary to a quarter row below it, straight into the next
        /// commit line. `top` is the source row's centre line in this row's coordinates.
        mutating func shift(from a: CGFloat, to b: CGFloat, top: CGFloat) {
            add(.move(CGPoint(x: a, y: top)))
            guard abs(b - a) <= path.spacing * GraphPath.wideShift else {
                wideShift(from: a, to: b, top: top)
                return
            }
            add(.line(CGPoint(x: a, y: top + height * GraphPath.shiftStraight)))
            let bend = CGPoint(x: b, y: top + height * (1 - GraphPath.shiftStraight))
            if rounded {
                add(
                    .curve(
                        bend, control1: CGPoint(x: a, y: top + height / 2), control2: CGPoint(x: b, y: top + height / 2)
                    ))
            } else {
                add(.line(bend))
            }
            add(.line(CGPoint(x: b, y: top + height)))
        }

        /// Across several lanes: a corner down, straight across on the boundary, a corner into the lane.
        private mutating func wideShift(from a: CGFloat, to b: CGFloat, top: CGFloat) {
            let boundary = top + height / 2
            let end = CGPoint(x: b, y: top + height)
            let radius = height * GraphPath.wideCornerRadius
            turn(
                at: CGPoint(x: a, y: boundary), from: CGPoint(x: a, y: top), to: CGPoint(x: b, y: boundary),
                radius: radius)
            turn(at: CGPoint(x: b, y: boundary), from: CGPoint(x: a, y: boundary), to: end, radius: radius)
            add(.line(end))
        }

        /// One S (rounded) or a diagonal with short straight ends (angled) from `a` down to `b`, vertical at both ends.
        mutating func bend(from a: CGPoint, to b: CGPoint) {
            let down = b.y - a.y
            add(.move(a))
            if rounded {
                add(
                    .curve(
                        b, control1: CGPoint(x: a.x, y: a.y + down / 2), control2: CGPoint(x: b.x, y: a.y + down / 2)))
            } else {
                add(.line(CGPoint(x: a.x, y: a.y + down * GraphPath.angledStraight)))
                add(.line(CGPoint(x: b.x, y: b.y - down * GraphPath.angledStraight)))
                add(.line(b))
            }
        }

        /// Into the node: down its lane, across at the centre line.
        mutating func incoming(_ edge: GraphEdge) {
            connect(edge, start: 0, end: path.middle, cornerFirst: true)
        }

        /// Out of the node: across, then down; a lane moving left bends across the boundary below instead.
        mutating func outgoing(_ edge: GraphEdge, in row: GraphRow, next: GraphRow?) {
            if GraphPath.rises(edge, in: row) {
                add(.move(CGPoint(x: path.x(edge.to), y: path.middle)))
                add(.line(CGPoint(x: path.x(edge.to), y: height)))
            } else if edge.from != edge.to && GraphPath.crossesBoundary(edge) {
                shift(from: path.x(edge.from), to: path.x(GraphPath.target(of: edge, next: next)), top: path.middle)
            } else {
                connect(edge, start: path.middle, end: height, cornerFirst: false)
            }
        }

        /// From `edge.from` at `start` to `edge.to` at `end`: straight in its own lane, else with one corner.
        private mutating func connect(_ edge: GraphEdge, start: CGFloat, end: CGFloat, cornerFirst: Bool) {
            let a = CGPoint(x: path.x(edge.from), y: start)
            let b = CGPoint(x: path.x(edge.to), y: end)
            add(.move(a))
            if edge.from != edge.to {
                let corner = cornerFirst ? CGPoint(x: a.x, y: b.y) : CGPoint(x: b.x, y: a.y)
                turn(at: corner, from: a, to: b, radius: min(abs(b.x - a.x), abs(end - start)) * GraphPath.cornerRadius)
            }
            add(.line(b))
        }
    }
}

extension CGPoint {
    fileprivate func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
    /// The point `length` from here toward `target`.
    fileprivate func moved(toward target: CGPoint, by length: CGFloat) -> CGPoint {
        let total = distance(to: target)
        return CGPoint(x: x + (target.x - x) / total * length, y: y + (target.y - y) / total * length)
    }
}
