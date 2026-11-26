import Foundation
import GitaCore

/// What a refresh keeps or reselects once a new snapshot arrives. Pure, so every path is tested without Git.
struct RefreshPlan {
    /// The review shown before the refresh.
    struct Before {
        var section: Section
        var operationIdentity: String?
        var historyIdentity: UUID?
        var ancestryIdentity: String?
        var commit: GitCommit?
        var stash: GitStash?
        var hasCommitDetails: Bool
        var isTreeReview: Bool
        /// The first commit of a branch focus, when one is shown.
        var focusedFirst: GitCommit?
        var isFocused: Bool
        var isSearching: Bool
        var isReviewingWorkingChanges = false
        var isAmending = false
    }

    enum Reselection: Equatable {
        /// A new operation stopped: the Changes page with the unstaged files.
        case enterChanges
        /// The Changes page again, keeping the file shown; `unstage` when a new operation stopped meanwhile.
        case refreshChanges(unstage: Bool)
        case stash(GitStash)
        /// The same commit: its loaded review stays; `notify` when the commit's decorations changed.
        case keep(GitCommit, notify: Bool)
        case select(GitCommit)
        case nothing
    }

    enum FocusUpdate: Equatable { case none, refocus, discard }

    var reselection: Reselection
    var restartsSearch: Bool
    var focus: FocusUpdate

    init(before: Before, next: RepositorySnapshot) {
        reselection = Self.reselection(before, next)
        restartsSearch = before.isSearching && before.historyIdentity != next.historyIdentity
        if before.isFocused, before.ancestryIdentity != next.ancestryIdentity {
            focus = before.section == .history ? .refocus : .discard
        } else {
            focus = .none
        }
    }

    private static func reselection(_ before: Before, _ next: RepositorySnapshot) -> Reselection {
        if let operation = next.operation, operation.identity != before.operationIdentity {
            return before.section == .changes ? .refreshChanges(unstage: true) : .enterChanges
        }
        if before.section == .changes
            || (before.isReviewingWorkingChanges && (!next.changes.isEmpty || before.isAmending))
        {
            return .refreshChanges(unstage: false)
        }
        if let stash = before.stash, next.stashes.contains(stash) { return .stash(stash) }
        let fallback = before.isFocused ? before.focusedFirst : next.commits.first
        guard let commit = next.commits.first(where: { $0.id == before.commit?.id }) ?? before.commit ?? fallback
        else { return .nothing }
        return commitReselection(commit, before, next)
    }

    /// A commit's files and diff cannot change under the same SHA, base and ancestry, nor a tree within the same
    /// validated all-ref identity: keep the loaded review (no Git processes, no blanked diff) while agents update
    /// the working tree, and only pick up new decorations.
    private static func commitReselection(
        _ commit: GitCommit, _ before: Before, _ next: RepositorySnapshot
    )
        -> Reselection
    {
        guard commit.id == before.commit?.id, before.hasCommitDetails else { return .select(commit) }
        if before.isTreeReview {
            let sameHistory = before.historyIdentity != nil && before.historyIdentity == next.historyIdentity
            return sameHistory ? .keep(commit, notify: true) : .select(commit)
        }
        guard before.ancestryIdentity == next.ancestryIdentity else { return .select(commit) }
        return .keep(commit, notify: commit != before.commit)
    }
}
