import Foundation
import GitaCore

/// Pure presenter for the pinned `26 pt` Working Changes row above the history clip view.
struct WorkingChangesRowState: Equatable {
    struct Input {
        var snapshot: RepositorySnapshot?
        var displayedCommits: [GitCommit]
        var graphs: [GraphRow]
        var isSearching: Bool
        var isAuthorFiltering: Bool
        var focusedReference: GitReference?
        var branchFilters: BranchFilters
        var isSelected: Bool
    }

    var isVisible: Bool
    var summaryText: String
    var unstagedCount: Int
    var stagedCount: Int
    var conflictCount: Int
    var headLane: Int
    var headColor: Int
    var isSelected: Bool

    init(_ input: Input) {
        isSelected = input.isSelected
        guard let snapshot = input.snapshot,
            let head = snapshot.head,
            !snapshot.changes.isEmpty,
            !input.isSearching,
            !input.isAuthorFiltering,
            Self.scopeContainsHead(
                head: head, snapshot: snapshot, focused: input.focusedReference,
                filters: input.branchFilters, displayedCommits: input.displayedCommits)
        else {
            isVisible = false
            summaryText = ""
            unstagedCount = 0
            stagedCount = 0
            conflictCount = 0
            headLane = 0
            headColor = 0
            return
        }
        isVisible = true
        conflictCount = snapshot.changes.count { $0.isConflict }
        unstagedCount = snapshot.changes.count { !$0.isConflict && $0.isUnstaged }
        stagedCount = snapshot.changes.count { !$0.isConflict && $0.isStaged }
        if let headIndex = input.displayedCommits.firstIndex(where: { $0.id == head }),
            input.graphs.indices.contains(headIndex)
        {
            headLane = input.graphs[headIndex].lane
            headColor = input.graphs[headIndex].color
        } else {
            headLane = 0
            headColor = 0
        }
        summaryText = Self.formatSummary(conflicts: conflictCount, unstaged: unstagedCount, staged: stagedCount)
    }

    private static func scopeContainsHead(
        head: String, snapshot: RepositorySnapshot, focused: GitReference?,
        filters: BranchFilters, displayedCommits: [GitCommit]
    ) -> Bool {
        if let focused {
            if focused.commit == head { return true }
            if let branch = snapshot.branch, focused.kind == .branch, focused.name == branch { return true }
            return displayedCommits.contains { $0.id == head }
        }
        if !filters.only.isEmpty {
            return snapshot.commits.contains { $0.id == head } || displayedCommits.contains { $0.id == head }
        }
        return true
    }

    private static func formatSummary(conflicts: Int, unstaged: Int, staged: Int) -> String {
        var parts = [String(localized: "Working Changes")]
        if conflicts > 0 { parts.append(String(localized: "\(conflicts) conflicts")) }
        if unstaged > 0 { parts.append(String(localized: "\(unstaged) unstaged")) }
        if staged > 0 { parts.append(String(localized: "\(staged) staged")) }
        return parts.joined(separator: " · ")
    }
}
