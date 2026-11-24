import Foundation
import GitaCore

/// Pure eligibility and ordering calculations for §6b multi-commit actions (`Cherry-pick N…`, `Revert N…`,
/// `Copy SHAs`, and `Squash…`).
struct MultiCommitActionEligibility: Equatable {
    var selectedCommits: [GitCommit]
    var canCherryPick: Bool
    var canRevert: Bool
    var canCopySHAs: Bool
    var squashBase: GitCommit?
    var squashPrefill: [String: GitRebaseAction]

    var canSquash: Bool { squashBase != nil && !squashPrefill.isEmpty }
    /// Oldest-first replay order for cherry-pick.
    var replayOrder: [GitCommit] { selectedCommits.reversed() }
    /// Newest-first order for revert.
    var revertOrder: [GitCommit] { selectedCommits }

    init(selectedIDs: [String], commits: [GitCommit], head: String?, canOperate: Bool) {
        let byID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = Self.orderNewestFirst(selectedIDs.compactMap { byID[$0] }, in: commits)
        selectedCommits = ordered
        canCopySHAs = !ordered.isEmpty
        let hasMerge = ordered.contains { $0.parents.count > 1 }
        let singleParentOnly = !ordered.isEmpty && !hasMerge
        canCherryPick = canOperate && singleParentOnly
        canRevert = canOperate && singleParentOnly

        if canOperate, ordered.count >= 3, let head,
            let resolved = Self.resolveLinearSquash(selected: ordered, head: head, byID: byID)
        {
            squashBase = resolved.base
            squashPrefill = resolved.prefill
        } else {
            squashBase = nil
            squashPrefill = [:]
        }
    }

    private static func orderNewestFirst(_ selected: [GitCommit], in allCommits: [GitCommit]) -> [GitCommit] {
        let positions = Dictionary(allCommits.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.sorted { (positions[$0.id] ?? .max) < (positions[$1.id] ?? .max) }
    }

    private static func resolveLinearSquash(
        selected: [GitCommit], head: String, byID: [String: GitCommit]
    ) -> (base: GitCommit, prefill: [String: GitRebaseAction])? {
        guard selected.allSatisfy({ $0.parents.count == 1 }) else { return nil }
        let selectedSet = Set(selected.map(\.id))
        var chain: [GitCommit] = []
        var cursorID: String? = head
        var steps = 0
        while let id = cursorID, let commit = byID[id], steps < 500 {
            steps += 1
            guard commit.parents.count <= 1 else { return nil }
            chain.append(commit)
            if selectedSet.contains(id), chain.suffix(selected.count).map(\.id) == selected.map(\.id) {
                break
            }
            if selected.last?.id == id { break }
            cursorID = commit.parents.first
        }
        guard chain.count >= selected.count else { return nil }
        // Verify all selected commits appear contiguously along the first-parent chain from HEAD.
        let matchingSlice = chain.drop { !selectedSet.contains($0.id) }
        guard matchingSlice.count >= selected.count else { return nil }
        let contiguous = Array(matchingSlice.prefix(selected.count))
        guard contiguous.map(\.id) == selected.map(\.id) else { return nil }
        guard let oldestParentID = contiguous.last?.parents.first, let base = byID[oldestParentID] else { return nil }
        var prefill: [String: GitRebaseAction] = [:]
        if let oldest = contiguous.last { prefill[oldest.id] = .pick }
        for commit in contiguous.dropLast() { prefill[commit.id] = .squash }
        return (base, prefill)
    }
}
