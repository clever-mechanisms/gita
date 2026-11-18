import Foundation
import GitaCore

/// The loaded history laid out for the list: the row index of every loaded commit, and the graph of the rows shown.
/// With Settings › Git › Collapse merged commits on, the rows shown leave out what collapsed merges brought in
/// (`CollapsedHistory`). Built off the main thread and set together with the snapshot it describes.
struct HistoryLayout: Sendable {
    /// What a collapsed history folds: every merge but `expanded`; `pinned` commits (HEAD) are never hidden.
    struct Folding: Sendable, Equatable {
        var expanded: Set<String>
        var pinned: Set<String>
    }
    var graph: [GraphRow] = []
    var state = GraphLayout.State()
    /// Row lookup and parent rows for all loaded commits.
    var index = HistoryIndex.empty
    /// True when merges are collapsed and only `shown` is listed; otherwise every loaded commit is shown.
    var isCollapsed = false
    /// The commits shown when the history is collapsed (empty when it is not).
    var shown: [GitCommit] = []
    var shownIndex = HistoryIndex.empty
    /// Per loaded row: the shown merge row hiding it, or -1 (empty when nothing is collapsed).
    var hiddenBy: [Int32] = []
    /// The folding this was built with.
    var folding: Folding?
    static let empty = Self()

    /// Whether this layout is still right for `count` loaded commits laid out with `folding`.
    func describes(_ count: Int, folding: Folding?) -> Bool {
        index.count == count && self.folding == folding && graph.count == (isCollapsed ? shown.count : count)
    }

    /// `graphCommits`: `commits` with the links the graph draws (author-tab or squash links when `linked`); `index`:
    /// the row index of `commits` when it is already built.
    static func build(
        _ commits: [GitCommit], graphCommits: [GitCommit], linked: Bool, index: HistoryIndex?, folding: Folding?
    ) -> Self {
        var layout = Self()
        layout.index = index ?? HistoryIndex(commits: commits)
        layout.folding = folding
        guard let folding else {
            let built = GraphLayout.build(commits: graphCommits, continuing: GraphLayout.State())
            layout.graph = built.rows
            layout.state = built.state
            return layout
        }
        // Squash links count as merges: the squashed branch folds into its squash commit.
        let graphIndex = linked ? HistoryIndex(commits: graphCommits) : layout.index
        let collapsed = graphIndex.collapsingMerges(graphCommits, expanded: folding.expanded, pinned: folding.pinned)
        let built = GraphLayout.build(commits: collapsed.graphCommits, continuing: GraphLayout.State())
        layout.graph = built.rows
        layout.state = built.state
        let shown = collapsed.rows.map { commits[$0] }
        layout.isCollapsed = true
        layout.shown = shown
        layout.shownIndex = HistoryIndex(commits: shown)
        layout.hiddenBy = collapsed.hiddenBy
        return layout
    }

    /// An uncollapsed layout continued with a further history page (`added` with their graph links; `all` every
    /// loaded commit, the new ones last): rows above cannot change, so only the page is laid out.
    func appending(_ added: [GitCommit], all: [GitCommit]) -> Self {
        var layout = self
        let page = GraphLayout.build(commits: added, continuing: state)
        layout.graph += page.rows
        layout.state = page.state
        layout.index = HistoryIndex(commits: all)
        return layout
    }
}
