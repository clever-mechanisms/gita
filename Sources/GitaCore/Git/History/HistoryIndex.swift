import Foundation

/// Row lookup and integer parent links for one loaded history page set (built off the main thread with the graph).
/// Requires the `git log --topo-order` invariant: every commit's ancestors appear after it.
public struct HistoryIndex: Sendable {
    public let rowByID: [String: Int]
    let parentRows: [[Int32]]
    /// Rows with at least one parent outside the loaded window.
    private let truncated: Set<Int32>
    public var count: Int { parentRows.count }

    public init(commits: [GitCommit]) {
        var rows = [String: Int](minimumCapacity: commits.count)
        for (row, commit) in commits.enumerated() { rows[commit.id] = row }
        rowByID = rows
        // Positional parents; -1 marks a parent outside the loaded window.
        let parents = commits.map { commit in commit.parents.map { rows[$0].map(Int32.init) ?? -1 } }
        parentRows = parents
        truncated = Set(parents.indices.lazy.filter { parents[$0].contains(-1) }.map(Int32.init))
    }
    public static let empty = Self(commits: [])

    public struct Merged: Sendable, Equatable {
        /// Rows a merge brought in, in history order, at most `limit`.
        public var rows: [Int]
        /// False when the walk was cut by the limit or reached the end of the loaded history (more may exist).
        public var complete: Bool
    }

    /// Commits reachable from a merge's other parents but not from its first parent (`git log P1..merge`), within the
    /// loaded rows. Visits rows in increasing (topological) order, painting first-parent and other-parent reachability
    /// like Git's merge-base walk, and stops once no other-parent-only row remains queued: cost follows the merged
    /// range, not the depth of the first-parent line. `alsoMerging` adds parents Git does not record (a squash merge's
    /// branch tip, which must come after `row`): they count as other parents.
    public func mergedRows(of row: Int, alsoMerging extra: [Int] = [], limit: Int = 200) -> Merged {
        guard parentRows.indices.contains(row) else { return Merged(rows: [], complete: true) }
        // Any path from the first parent to a loaded row runs through loaded rows (they are its descendants and
        // precede it), so a first parent outside the window cannot hide a merged row; it only ends that side early.
        let parents = parentRows[row] + extra.filter { $0 > row && $0 < parentRows.count }.map(Int32.init)
        guard parents.count > 1 else { return Merged(rows: [], complete: true) }
        var painter = ReachabilityPainter()
        painter.paint(parents[0], .first)
        for parent in parents.dropFirst() { painter.paint(parent, .other) }
        var result: [Int] = []
        // A merged-in parent that is not loaded yet hides everything behind it: the count can only grow later.
        var reachedEnd = parents.dropFirst().contains(-1)
        while let step = painter.next() {
            let (next, flag) = step
            if flag == .other {
                result.append(Int(next))
                if result.count >= limit { return Merged(rows: result, complete: false) }
                if truncated.contains(next) { reachedEnd = true }
            }
            for parent in parentRows[Int(next)] { painter.paint(parent, flag) }
        }
        return Merged(rows: result, complete: !reachedEnd)
    }
}

/// Which side of a merge reaches each queued row: its first parent, its other parents, or both.
private struct ReachabilityPainter {
    struct Side: OptionSet {
        let rawValue: UInt8
        static let first = Self(rawValue: 1)
        static let other = Self(rawValue: 2)
    }

    private var flags: [Int32: Side] = [:]
    private var heap = MinHeap()
    private var otherOnlyQueued = 0

    /// Each row is queued once: rows are popped in order, after all their descendants.
    mutating func paint(_ target: Int32, _ side: Side) {
        guard target >= 0 else { return }
        let old = flags[target] ?? []
        let new = old.union(side)
        guard new != old else { return }
        flags[target] = new
        if old.isEmpty {
            heap.push(target)
            if new == .other { otherOnlyQueued += 1 }
        } else if old == .other {
            otherOnlyQueued -= 1
        }
    }

    /// The next row in topological order while a row reached only from the other side remains queued.
    mutating func next() -> (row: Int32, side: Side)? {
        guard otherOnlyQueued > 0, let row = heap.pop() else { return nil }
        let side = flags[row] ?? []
        if side == .other { otherOnlyQueued -= 1 }
        return (row, side)
    }
}
