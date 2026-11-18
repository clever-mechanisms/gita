import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Past `GraphCell.maximumLanes` lanes the graph stops at an edge with a count; narrower graphs are drawn as before.
@MainActor
struct GraphOverflowTests {
    private static let limit = GraphCell.maximumLanes

    /// A row whose node is on `lane` with straight lines through every lane up to `last`.
    private static func row(lane: Int, last: Int) -> GraphRow {
        let through = (0...last).filter { $0 != lane }.map { GraphEdge(from: $0, to: $0, color: $0) }
        return GraphRow(
            lane: lane, color: lane, incoming: through + [GraphEdge(from: lane, to: lane, color: lane)],
            outgoing: through + [GraphEdge(from: lane, to: lane, color: lane)])
    }

    private static func pixels(_ cell: GraphCell) throws -> Data {
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @Test func theColumnStopsGrowingAtTheLimit() {
        #expect(GraphCell.width(lastLane: 3, scale: 1) == CGFloat(10 * 2 + 4 + 3 * 16))
        #expect(GraphCell.width(lastLane: Self.limit - 1, scale: 2) == (10 * 2 + 4 + CGFloat(Self.limit - 1) * 16) * 2)
        let capped = GraphCell.width(lastLane: Self.limit, scale: 1)
        #expect(capped > GraphCell.width(lastLane: Self.limit - 1, scale: 1))
        #expect(GraphCell.width(lastLane: 300, scale: 1) == capped)
        #expect(capped < 720)
    }

    @Test func overflowCountsTheLanesPastTheEdge() throws {
        #expect(GraphOverflow(row: Self.row(lane: 2, last: Self.limit - 1), limit: Self.limit) == nil)
        let wide = try #require(GraphOverflow(row: Self.row(lane: 2, last: 299), limit: Self.limit))
        #expect(wide.hidden == 300 - Self.limit)
        #expect(!wide.nodeHidden)
        #expect((wide.lane, wide.lanes) == (3, 300))
        let far = try #require(GraphOverflow(row: Self.row(lane: 120, last: 299), limit: Self.limit))
        #expect(far.nodeHidden)
        // A merge line out to a lane past the edge counts too.
        let merge = GraphRow(
            lane: 0, color: 0, incoming: [],
            outgoing: [GraphEdge(from: 0, to: 0, color: 0), GraphEdge(from: 0, to: Self.limit, color: 1)])
        #expect(GraphOverflow(row: merge, limit: Self.limit)?.hidden == 1)
    }

    /// The limit changes no pixel of a graph within it.
    @Test func graphsWithinTheLimitDrawExactlyAsWithoutIt() throws {
        UITestSupport.bootstrap()
        func commit(_ id: Int, _ parents: [Int]) -> GitCommit {
            GitCommit(
                id: String(format: "%040x", id), parents: parents.map { String(format: "%040x", $0) },
                subject: "c\(id)", author: "A", date: Date(timeIntervalSince1970: 0))
        }
        let commits = (1...12).map { commit($0, $0 < 12 ? [$0 + 1] : []) }
        // Branch tips that join the line further down, and a merge: a few lanes open at once.
        let forks = [commit(101, [7, 100]), commit(100, [6]), commit(102, [8]), commit(103, [9])]
        let rows = GraphLayout.build(commits: forks + commits)
        #expect(rows.map(GraphOverflow.lastLane(of:)).max() ?? 0 >= 3)
        let cell = GraphCell(frame: NSRect(x: 0, y: 0, width: GraphCell.width(lastLane: 6, scale: 1), height: 24))
        for index in rows.indices {
            cell.previous = index > 0 ? rows[index - 1] : nil
            cell.row = rows[index]
            cell.next = index + 1 < rows.count ? rows[index + 1] : nil
            cell.isMerge = false
            cell.laneLimit = Int.max
            let unlimited = try Self.pixels(cell)
            cell.laneLimit = Self.limit
            #expect(try Self.pixels(cell) == unlimited, "row \(index)")
        }
    }

    /// Lines left out of a wide row before its strokes are built lie wholly past the edge: the row draws the same.
    @Test func linesLeftOutLieWhollyPastTheEdge() {
        func commit(_ id: String, _ parents: [String]) -> GitCommit {
            GitCommit(id: id, parents: parents, subject: id, author: "A", date: Date(timeIntervalSince1970: 0))
        }
        // Sixty branches with two commits each, folding back into one root: lanes past the edge shift left across it.
        let width = 60
        let tips = (0..<width).map { commit("t\($0)", ["m\($0)"]) }
        let middles = (0..<width).map { commit("m\($0)", ["root"]) }
        let rows = GraphLayout.build(commits: tips + middles + [commit("root", [])])
        #expect(rows.contains { GraphOverflow(row: $0, limit: Self.limit) != nil })
        let path = GraphPath(spacing: 16, offset: 10, height: 24, style: .rounded)
        let edge = path.x(Self.limit) - path.spacing / 2
        func points(_ stroke: GraphPath.Stroke) -> [CGPoint] {
            stroke.elements.flatMap { element -> [CGPoint] in
                switch element {
                case .move(let point), .line(let point): [point]
                case .arc(let corner, let next, _): [corner, next]
                case .curve(let point, let control1, let control2): [point, control1, control2]
                }
            }
        }
        for index in rows.indices where GraphOverflow(row: rows[index], limit: Self.limit) != nil {
            let previous = index > 0 ? rows[index - 1] : nil
            let next = index + 1 < rows.count ? rows[index + 1] : nil
            let all = path.strokes(row: rows[index], previous: previous, next: next)
            let visible = path.strokes(
                row: GraphOverflow.visible(rows[index], limit: Self.limit),
                previous: previous.map { GraphOverflow.visible($0, limit: Self.limit) },
                next: next.map { GraphOverflow.visible($0, limit: Self.limit) })
            let reaching = all.filter { points($0).contains { $0.x < edge } }
            #expect(reaching.allSatisfy(visible.contains), "row \(index)")
        }
    }

    /// A wide row is drawn up to the edge, with its count, and its graph tooltip says where the commit is.
    @Test func wideRowsStopAtTheEdge() throws {
        UITestSupport.bootstrap()
        let width = GraphCell.width(lastLane: 299, scale: 1)
        let cell = GraphCell(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        cell.row = Self.row(lane: 120, last: 299)
        let capped = try Self.pixels(cell)
        cell.laneLimit = Int.max
        #expect(try Self.pixels(cell) != capped)

        let commitCell = HistoryCommitCell(frame: NSRect(x: 0, y: 0, width: width + 300, height: 24))
        commitCell.configure(
            .init(
                commit: GitCommit(
                    id: String(repeating: "a", count: 40), parents: [], subject: "Deep", author: "A",
                    date: Date(timeIntervalSince1970: 0)),
                row: Self.row(lane: 120, last: 299), previous: nil, next: nil, scale: 1, isHead: false,
                remoteNames: [], merge: nil))
        commitCell.layout()
        #expect(commitCell.graph.frame.width == width)
        let tip = commitCell.view(commitCell, stringForToolTip: 0, point: NSPoint(x: 5, y: 12), userData: nil)
        #expect(tip.contains("121"))
        #expect(tip.contains("300"))
    }
}
