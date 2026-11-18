import Foundation

/// The history with merged branches folded away (Settings › Git › Collapse merged commits): a merge keeps its row
/// and its "N commits" chip, and the commits it brought in (`HistoryIndex.mergedRows`) are hidden until that merge is
/// expanded. Merges inside an expanded merge stay collapsed until they are expanded too.
public struct CollapsedHistory: Sendable, Equatable {
    /// The rows of the full list that are shown, in order.
    public var rows: [Int]
    /// The shown commits with the links the graph draws. A collapsed merge keeps only its first parent, so the line
    /// runs straight through it. A hidden parent is replaced by the merge that hid it when that merge is further down
    /// (a branch that went on after a merge leaves from that merge), else by its first shown first-parent ancestor.
    public var graphCommits: [GitCommit]
    /// For each row of the full list: the shown merge that hides it, or -1 when it is shown.
    public var hiddenBy: [Int32]
}

extension HistoryIndex {
    /// Folds every merge not in `expanded` (commit IDs); `pinned` commits (HEAD) are never hidden. `commits` are the
    /// commits this index was built from, in the same order; any other list gives an empty result.
    public func collapsingMerges(
        _ commits: [GitCommit], expanded: Set<String>, pinned: Set<String> = []
    ) -> CollapsedHistory {
        guard commits.count == count else { return CollapsedHistory(rows: [], graphCommits: [], hiddenBy: []) }
        let expandedRows = Set(expanded.compactMap { rowByID[$0] })
        let hiddenBy = foldedRows(expanded: expandedRows, pinned: Set(pinned.compactMap { rowByID[$0] }))
        var rows: [Int] = []
        var graphCommits: [GitCommit] = []
        rows.reserveCapacity(count)
        graphCommits.reserveCapacity(count)
        for row in 0..<count where hiddenBy[row] < 0 {
            var commit = commits[row]
            commit.parents = graphParents(
                row, commits: commits, folded: !expandedRows.contains(row), hiddenBy: hiddenBy)
            rows.append(row)
            graphCommits.append(commit)
        }
        return CollapsedHistory(rows: rows, graphCommits: graphCommits, hiddenBy: hiddenBy)
    }

    /// Top-down: a merge hidden by one above it is folded with it; ranges of shown merges on one line are disjoint,
    /// so the walks together cost about one pass over the loaded history.
    private func foldedRows(expanded: Set<Int>, pinned: Set<Int>) -> [Int32] {
        var hiddenBy = [Int32](repeating: -1, count: count)
        for row in 0..<count where hiddenBy[row] < 0 && parentRows[row].count > 1 && !expanded.contains(row) {
            for merged in mergedRows(of: row, limit: .max).rows where hiddenBy[merged] < 0 && !pinned.contains(merged) {
                hiddenBy[merged] = Int32(row)
            }
        }
        return hiddenBy
    }

    /// A shown row's parents in the folded graph; a folded merge keeps only its first parent.
    private func graphParents(_ row: Int, commits: [GitCommit], folded: Bool, hiddenBy: [Int32]) -> [String] {
        let links = parentRows[row]
        var parents: [String] = []
        for (number, link) in links.enumerated() where number == 0 || !(folded && links.count > 1) {
            // A parent outside the loaded rows keeps its ID: its lane stays open, as on any history page.
            let id =
                link < 0
                ? commits[row].parents[number]
                : shownRow(for: link, from: row, hiddenBy: hiddenBy).map { commits[Int($0)].id }
            if let id, !parents.contains(id) { parents.append(id) }
        }
        return parents
    }

    /// The row a link to hidden `start` from shown `row` is drawn to; nil when it leads out of the loaded rows.
    private func shownRow(for start: Int32, from row: Int, hiddenBy: [Int32]) -> Int32? {
        var current = start
        while current >= 0 {
            let hider = hiddenBy[Int(current)]
            if hider < 0 { return current }
            if Int(hider) > row { return hider }
            current = parentRows[Int(current)].first ?? -1 // rows only grow: the walk ends
        }
        return nil
    }
}
