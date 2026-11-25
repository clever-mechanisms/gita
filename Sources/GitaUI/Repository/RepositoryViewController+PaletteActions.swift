import AppKit
import GitaCore

/// What the window's own buttons and links do, offered to the command palette: Create PR… (the worktree strip),
/// Stage all and Commit staged (Local Changes). The menu bar has no item for them.
extension RepositoryViewController {
    /// Each action as a menu item, disabled while it cannot run, with more words it is found by.
    func paletteActions() -> [(item: NSMenuItem, keywords: [String])] {
        let snapshot = model.snapshot
        let idle = snapshot != nil && !model.isMutating
        let canCreate =
            snapshot.map { WorktreeStripPresenter.branch(of: $0) != nil && $0.github?.webURL != nil }
            ?? false
        let hasUnstaged = snapshot?.changes.contains { $0.isUnstaged && !$0.isConflict } == true
        let canCommit =
            (model.hasStagedChanges || amend.source != nil) && snapshot?.operation == nil
            && !model.hasConflicts
        let create = MenuAction(String(localized: "Create PR…"), symbol: Section.pullRequests.symbol) { [weak self] in
            self?.createPullRequest()
        }
        create.isEnabled = idle && canCreate
        let stage = MenuAction(String(localized: "Stage all"), symbol: "plus.square") { [weak self] in
            self?.stageAllFiles()
        }
        stage.isEnabled = idle && hasUnstaged
        let commit = MenuAction(String(localized: "Commit staged"), symbol: "checkmark") { [weak self] in
            self?.composeCommit()
        }
        commit.isEnabled = idle && canCommit
        return [
            (create, ["pull request", "new pr", "open pr", "github"]), (stage, ["add", "stage everything"]),
            (commit, ["commit message", "save"]),
        ] + bisectPaletteActions()
    }

    /// Local Changes with the commit message ready to type: Commit staged follows there.
    private func composeCommit() {
        if model.section != .changes { model.section = .changes }
        view.window?.makeFirstResponder(commitFooter.field)
    }
}
