import GitaCore

/// What switching to a branch, remote branch or tag means from this checkout: open the linked worktree that already
/// has the branch, check it out here, or nothing when this checkout is already on it. The reference menu's first
/// items and a double-click on a history pill both follow it.
struct ReferenceSwitch {
    enum Action: Equatable {
        /// A linked worktree has the branch (or the local branch a remote branch names): open it in a tab.
        case openWorktree(path: String)
        /// Check it out here. A remote branch lands on its local branch and fast-forwards it where it can, a tag
        /// detaches (`GitService.checkout(ref:)`).
        case checkout(fullName: String)
        /// Already on the local branch this reference names, at this commit.
        case none
    }

    var snapshot: RepositorySnapshot

    func action(_ reference: GitReference) -> Action {
        if let worktree = occupiedWorktree(reference) { return .openWorktree(path: worktree.path) }
        if standingOn(reference) { return .none }
        return .checkout(fullName: reference.fullName)
    }

    /// The linked worktree that has this branch, or the local branch a remote-tracking branch names.
    func occupiedWorktree(_ reference: GitReference) -> GitWorktree? {
        let branch = reference.kind == .branch ? reference.name : localBranch(matching: reference)?.name
        guard let branch else { return nil }
        return snapshot.worktrees.dropFirst().first { !$0.isBare && $0.branch == branch }
    }

    /// Already on the local branch this reference names, at this commit: checking it out would not move.
    func standingOn(_ reference: GitReference) -> Bool {
        if reference.isCurrent { return true }
        guard let local = localBranch(matching: reference) else { return false }
        return local.isCurrent && local.commit == reference.commit
    }

    /// The local branch a remote-tracking branch names (`origin/main` → `main`); nil for `HEAD` and anything else.
    func localBranch(matching reference: GitReference) -> GitReference? {
        guard reference.kind == .remote else { return nil }
        let name = RemoteBranchName.branchName(reference)
        guard name != "HEAD" else { return nil }
        return snapshot.references.first { $0.kind == .branch && $0.name == name }
    }
}
