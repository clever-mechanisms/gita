import Foundation
import Testing

@testable import GitaCore

struct HistoryCollapseTests {
    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "A", date: Date())
    }
    private func shown(
        _ commits: [GitCommit], expanded: Set<String> = [], pinned: Set<String> = []
    ) -> [String: [String]] {
        let collapsed = HistoryIndex(commits: commits).collapsingMerges(commits, expanded: expanded, pinned: pinned)
        #expect(GraphLayout.build(commits: collapsed.graphCommits).count == collapsed.rows.count)
        return Dictionary(uniqueKeysWithValues: collapsed.graphCommits.map { ($0.id, $0.parents) })
    }

    /// A feature branch merged once and then continued: the merge folds the merged commits away, and the branch's
    /// newer commit leaves from the merge.
    private let continued = [
        GitCommit(id: "t", parents: ["f2"], subject: "", author: "", date: Date()),
        GitCommit(id: "M", parents: ["a", "f2"], subject: "", author: "", date: Date()),
        GitCommit(id: "a", parents: ["base"], subject: "", author: "", date: Date()),
        GitCommit(id: "f2", parents: ["f1"], subject: "", author: "", date: Date()),
        GitCommit(id: "f1", parents: ["base"], subject: "", author: "", date: Date()),
        GitCommit(id: "base", parents: [], subject: "", author: "", date: Date()),
    ]

    @Test func mergeHidesWhatItBroughtIn() {
        let rows = shown(continued)
        #expect(rows == ["t": ["M"], "M": ["a"], "a": ["base"], "base": []])
        let collapsed = HistoryIndex(commits: continued).collapsingMerges(continued, expanded: [])
        #expect(collapsed.rows == [0, 1, 2, 5])
        #expect(collapsed.hiddenBy == [-1, -1, -1, 1, 1, -1])
    }

    @Test func expandedMergeShowsItsCommits() {
        #expect(
            shown(continued, expanded: ["M"]) == [
                "t": ["f2"], "M": ["a", "f2"], "a": ["base"], "f2": ["f1"], "f1": ["base"], "base": [],
            ])
    }

    @Test func pinnedCommitStaysShown() {
        #expect(
            shown(continued, pinned: ["f1"]) == ["t": ["M"], "M": ["a"], "a": ["base"], "f1": ["base"], "base": []])
    }

    @Test func nestedMergeStaysFoldedUntilExpanded() {
        let commits = [
            commit("M", ["a", "N"]), commit("N", ["g1", "h1"]), commit("h1", ["g0"]), commit("g1", ["g0"]),
            commit("a", ["base"]), commit("g0", ["base"]), commit("base", []),
        ]
        #expect(shown(commits) == ["M": ["a"], "a": ["base"], "base": []])
        #expect(
            shown(commits, expanded: ["M"]) == [
                "M": ["a", "N"], "N": ["g1"], "g1": ["g0"], "a": ["base"], "g0": ["base"], "base": [],
            ])
        #expect(shown(commits, expanded: ["M", "N"]).count == commits.count)
    }

    @Test func linearHistoryIsUnchanged() {
        let commits = [commit("c", ["b"]), commit("b", ["a"]), commit("a", ["z"])] // "z" is not loaded yet
        let collapsed = HistoryIndex(commits: commits).collapsingMerges(commits, expanded: [])
        #expect(collapsed.graphCommits == commits)
        #expect(collapsed.rows == [0, 1, 2])
    }
}
