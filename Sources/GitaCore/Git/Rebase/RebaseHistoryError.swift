import Foundation

/// The repository or the chosen range cannot be edited with an interactive rebase.
enum RebaseHistoryError: Error, LocalizedError, Sendable {
    case gitTooOld
    case notLocalBranch
    case indexNotFull
    case noAncestor
    case rangeTooLong
    case nonlinearRange
    case notHeadAncestry
    case incompleteHistory
    case replacementRefs
    case worktreeNotOwned

    var errorDescription: String? {
        switch self {
        case .gitTooOld: String(localized: "Editing a rebase plan requires Git 2.45 or later.")
        case .notLocalBranch: String(localized: "This HEAD does not name a local branch.")
        case .indexNotFull:
            String(
                localized: """
                    Interactive rebase requires a full index without hidden tracked entries, conflicts, \
                    or submodules.
                    """)
        case .noAncestor: String(localized: "Choose an ancestor before at least one current-branch commit.")
        case .rangeTooLong: String(localized: "Choose a range of at most 500 commits.")
        case .nonlinearRange:
            String(
                localized: """
                    Choose a linear ancestor range. Merge-containing or unrelated histories cannot be \
                    edited here.
                    """)
        case .notHeadAncestry: String(localized: "The selected range is not the current HEAD ancestry.")
        case .incompleteHistory:
            String(localized: "Finish bisect and use a complete history without grafts before editing commits.")
        case .replacementRefs: String(localized: "Remove replacement refs before editing this history.")
        case .worktreeNotOwned: String(localized: "This rebase requires a worktree owned by the current user.")
        }
    }
}
