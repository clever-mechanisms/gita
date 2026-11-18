import GitaCore

/// Everything a history layout is built from, captured on the main actor and built off it.
struct HistoryLayoutInput: Sendable {
    /// A collapsed history reads further pages until it shows this many rows…
    static let collapsedMinimumRows = 150
    /// …unless this many commits are loaded already.
    static let collapsedMaximumCommits = 20_000

    var commits: [GitCommit]
    var graphCommits: [GitCommit]
    var linked: Bool
    var index: HistoryIndex?
    var folding: HistoryLayout.Folding?

    func build() -> HistoryLayout {
        HistoryLayout.build(commits, graphCommits: graphCommits, linked: linked, index: index, folding: folding)
    }

    /// The layout, after expanding every collapsed merge that hides `target` (an expanded merge can still fold the
    /// target into a merge inside it), and the folding it was built with (its expanded merges); nil when nothing folds.
    func build(revealing target: String?) -> (HistoryLayout, HistoryLayout.Folding?) {
        var folding = folding
        var layout = build()
        while let target, var opened = folding, let row = layout.index.rowByID[target],
            let merge = layout.hidingRow(of: row), opened.expanded.insert(commits[merge].id).inserted
        {
            folding = opened
            layout = HistoryLayout.build(
                commits, graphCommits: graphCommits, linked: linked, index: layout.index, folding: folding)
        }
        return (layout, folding)
    }
}

extension HistoryLayout {
    /// The row of the shown merge that folds `row` away, nil when `row` is shown.
    func hidingRow(of row: Int) -> Int? {
        guard hiddenBy.indices.contains(row), hiddenBy[row] >= 0 else { return nil }
        return Int(hiddenBy[row])
    }
}
