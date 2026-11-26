import Foundation
import GitaCore

/// The app-level actions the repository window's menus and buttons start (tabs, prompts, Git writes).
/// Each tab's `RepositoryCommandResponder` performs them (the shell sets it); tests record them.
@MainActor
protocol RepositoryCommands: AnyObject {
    func openRepositoryTab(_ url: URL)
    func openAuthorTab(_ author: CommitAuthor, in root: URL)
    func removeFromRepositoryList(_ paths: [String])
    func newBranchFrom(_ startPoint: String, suggestion: String)
    func checkoutReference(_ fullName: String)
    func advanceLocalBranch(_ fullName: String)
    func newWorktreeFor(branch: String)
    func newWorktree()
    func pull()
    func push()
    func forcePush()
    func pushBranch(_ name: String)
    func mergeReference(_ fullName: String)
    func rebaseOntoReference(_ fullName: String)
    func createTagAt(_ commit: GitCommit)
    /// Cherry-pick `commit` onto the current branch, reviewed first like Repository › Cherry-pick….
    func cherryPick(_ commit: GitCommit)
    func pushTag(_ name: String, to remote: String?)
    func deleteRemoteTag(_ name: String, on remote: String)
    func openStackedBranches(baseBranch: String?)
}

extension RepositoryCommands {
    func openStackedBranches(baseBranch _: String?) {}
}
