import Foundation

extension SignalState {
    public var localizedTitle: String {
        switch self {
        case .success: String(localized: "Success")
        case .failure: String(localized: "Failure")
        case .running: String(localized: "Running")
        case .pending: String(localized: "Pending")
        case .cancelled: String(localized: "Cancelled")
        case .neutral: String(localized: "Neutral")
        }
    }
}

extension GitOperationKind {
    public var localizedTitle: String {
        switch self {
        case .merge: String(localized: "Merge")
        case .rebase: String(localized: "Rebase")
        case .cherryPick: String(localized: "Cherry-pick")
        case .revert: String(localized: "Revert")
        case .apply: String(localized: "Apply patch")
        }
    }
}

extension GitPullMode {
    public var localizedTitle: String {
        switch self {
        case .fastForwardOnly: String(localized: "Fast-forward only")
        case .merge: String(localized: "Merge")
        case .rebase: String(localized: "Rebase")
        }
    }
}

extension GitMergeMode {
    public var localizedTitle: String {
        switch self {
        case .automatic: String(localized: "Fast-forward when possible")
        case .noFastForward: String(localized: "Create merge commit")
        case .fastForwardOnly: String(localized: "Fast-forward only")
        }
    }
}

extension GitRebaseAction {
    public var localizedTitle: String {
        switch self {
        case .pick: String(localized: "Pick")
        case .reword: String(localized: "Reword")
        case .edit: String(localized: "Edit")
        case .squash: String(localized: "Squash")
        case .fixup: String(localized: "Fixup")
        case .drop: String(localized: "Drop")
        }
    }
}

extension HistorySearchField {
    public var localizedTitle: String {
        switch self {
        case .message: String(localized: "Message")
        case .author: String(localized: "Author")
        case .path: String(localized: "Path")
        case .commit: String(localized: "Commit")
        }
    }
}

/// The labels of a checkout without a branch. The stored branch is only ever a real name (nil when there is none).
enum CheckoutLabel {
    static var detached: String { String(localized: "Detached HEAD") }
    static var bare: String { String(localized: "Bare") }
    static var unborn: String { String(localized: "Unborn branch") }

    /// Branch names cannot contain spaces, so these labels never hide a real name.
    static func branch(_ name: String) -> String { name == "Unborn branch" ? unborn : name }
}

extension RepositorySnapshot {
    /// Display only: a real branch name verbatim (even one named Bare); without a branch, Bare when the
    /// selected repository's own worktree record proves that it is bare, else Detached HEAD.
    public var localizedBranch: String {
        guard let branch else {
            let bare = worktrees.contains { $0.isBare && $0.path.utf8.elementsEqual(root.path.utf8) }
            return bare ? CheckoutLabel.bare : CheckoutLabel.detached
        }
        return CheckoutLabel.branch(branch)
    }
}

extension GitWorktree {
    /// Display only: a real branch name verbatim; Bare or Detached HEAD without one (also for an empty name).
    public var localizedBranch: String {
        if isBare { return CheckoutLabel.bare }
        guard let branch, !branch.isEmpty else { return CheckoutLabel.detached }
        return CheckoutLabel.branch(branch)
    }
}
