import GitaCore

/// The graph's view of the loaded commits: their real parents, or in an author tab the author-only links. With
/// Settings › Git › Squash merges on, a squash commit also links to the tip of the branch it squashed, so the branch
/// is drawn leaving the line and joining it again at that commit, like a merge. Only the graph sees that link.
enum HistoryGraphInput {
    /// An author tab's commits linked by `links` (`AuthorHistory.graphParents`) instead of their parents.
    static func lens(_ commits: [GitCommit], links: [String: [String]]) -> [GitCommit] {
        commits.map { commit in
            var copy = commit
            copy.parents = links[commit.id] ?? []
            return copy
        }
    }

    /// The commits with each squash commit also linked to the tip it squashed.
    static func make(_ commits: [GitCommit], squashLinks: [String: String]) -> [GitCommit] {
        guard !squashLinks.isEmpty else { return commits }
        let rows = HistoryPage.rows(commits)
        return commits.enumerated().map { row, commit in
            // The tip must come after its squash commit (the layout and the index walk rows top-down).
            guard let tip = squashLinks[commit.id], let tipRow = rows[tip], tipRow > row else { return commit }
            var copy = commit
            copy.parents.append(tip)
            return copy
        }
    }
}
