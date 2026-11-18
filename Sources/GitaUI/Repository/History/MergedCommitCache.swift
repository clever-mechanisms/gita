import GitaCore

/// Merged commit IDs per merge SHA: the commits a merge brought in, reachable from its other parents but not from the
/// first parent, within the loaded history. A complete walk never changes (commits are immutable), so it survives
/// reloads until grafts or replacement refs change ancestry; an incomplete one lasts for one displayed list.
struct MergedCommitCache {
    private struct Entry {
        var ids: [String]
        var complete: Bool
    }
    private var entries: [String: Entry] = [:]
    private var ancestry: String?

    /// The list was reloaded with `ancestry` (ancestry identity plus squash revision).
    mutating func listReloaded(ancestry next: String) {
        if next != ancestry {
            entries = [:]
            ancestry = next
        } else {
            entries = entries.filter(\.value.complete)
        }
    }

    /// A page was appended: walks cut short by the old end of the list may now be longer. Returns their merges.
    mutating func dropIncomplete() -> [String] {
        let incomplete = entries.filter { !$0.value.complete }.map(\.key)
        for id in incomplete { entries[id] = nil }
        return incomplete
    }

    /// The commits `merge` brought in (`squashTip`: the branch tip a squash commit squashed).
    mutating func ids(
        of merge: GitCommit, squashTip: String?, history: (index: HistoryIndex, commits: [GitCommit])
    ) -> [String] {
        guard merge.parents.count > 1 || squashTip != nil else { return [] }
        if let cached = entries[merge.id] { return cached.ids }
        let (index, commits) = history
        guard index.count == commits.count, let row = index.rowByID[merge.id] else { return [] }
        let also = squashTip.flatMap { index.rowByID[$0] }.map { [$0] } ?? []
        let merged = index.mergedRows(of: row, alsoMerging: also)
        let ids = merged.rows.map { commits[$0].id }
        entries[merge.id] = Entry(ids: ids, complete: merged.complete)
        return ids
    }

    /// The loaded commits for merged IDs, in history order (a cached walk may name commits beyond this list).
    static func commits(_ ids: [String], in history: (index: HistoryIndex, commits: [GitCommit])) -> [GitCommit] {
        guard history.index.count == history.commits.count else { return [] }
        return ids.compactMap { history.index.rowByID[$0].map { history.commits[$0] } }
    }
}
