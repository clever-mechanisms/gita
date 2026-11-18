import AppKit
import GitaCore

/// One repository tab's Git commands: the Repository menu's, also started from the toolbar, the sidebar and the
/// history's context menus. They run on that tab's model, asking first in a sheet on the main window where they need
/// input. The shell puts the selected tab's responder right after the application in the responder chain, so the
/// menus' nil-targeted items reach it whichever window is key; validation stays the shell's (`MenuAvailability`).
@MainActor
final class RepositoryCommandResponder: NSResponder, NSMenuItemValidation, RepositoryCommands {
    let model: AppModel
    private(set) weak var host: (any RepositoryCommandHost)?

    init(model: AppModel, host: any RepositoryCommandHost) {
        self.model = model
        self.host = host
        super.init()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    var system: AppSystemHooks? { host?.environment.system }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { host?.validateMenuItem(menuItem) ?? false }

    // MARK: App-level actions of the tab's menus

    func openRepositoryTab(_ url: URL) { host?.openRepositoryTab(url) }
    func openAuthorTab(_ author: CommitAuthor, in root: URL) { host?.openAuthorTab(author, in: root) }
    func removeFromRepositoryList(_ paths: [String]) { host?.removeFromRepositoryList(paths) }

    // MARK: Remotes and the working copy

    @objc func reveal() {
        if let root = model.snapshot?.root { system?.revealInFinder(root) }
    }

    @objc func newBranch() { newBranchNamed("") }

    /// New Branch with a name already filled in (the palette's ⌘N: what was typed there).
    func newBranchNamed(_ suggestion: String) {
        promptNewBranch(suggestion: suggestion) { git, name in try await git.createBranch(name: name) }
    }

    /// New Branch from a branch, tag or commit: created there and checked out.
    func newBranchFrom(_ startPoint: String, suggestion: String = "") {
        promptNewBranch(suggestion: suggestion) { git, name in try await git.createBranch(name: name, from: startPoint)
        }
    }

    private func promptNewBranch(
        suggestion: String, create: @escaping @Sendable (GitService, String) async throws -> Void
    ) {
        prompt(String(localized: "New branch"), labels: [String(localized: "Branch name")], defaults: [suggestion]) {
            [weak self] values in
            let name = values[0]
            self?.model.perform(String(localized: "Create branch")) { try await create($0, name) }
        }
    }

    /// Switch Branch… (⇧⌘K by default): the command palette showing the branches alone.
    @objc func switchBranch() {
        guard model.snapshot != nil else { return }
        host?.showPalette(scope: .branch)
    }

    /// A branch chosen in the palette: the worktree that has it, else the branch checked out here.
    func choose(_ entry: BranchPaletteEntry) {
        if let worktree = entry.worktree {
            openRepositoryTab(URL(fileURLWithPath: worktree, isDirectory: true))
        } else if !entry.isCurrent {
            checkoutReference(entry.fullName)
        }
    }

    func checkoutReference(_ fullName: String) {
        model.perform(String(localized: "Switch branch")) { try await $0.checkout(ref: fullName) }
    }

    /// Moves the local branch of the same name onto a remote-tracking branch, when that is a fast-forward.
    func advanceLocalBranch(_ fullName: String) {
        model.perform(String(localized: "Advance branch")) { try await $0.advanceLocalBranch(to: fullName) }
    }

    @objc func stash() {
        prompt(String(localized: "Stash changes"), labels: [String(localized: "Message")], defaults: [""]) {
            [weak self] values in
            self?.model.perform(String(localized: "Stash")) { try await $0.stash(message: values[0]) }
        }
    }

    @objc func newWorktree() {
        guard let root = model.snapshot?.root else { return }
        let directory = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-worktree")
        prompt(
            String(localized: "New worktree"),
            labels: [String(localized: "New branch"), String(localized: "Directory")], defaults: ["", directory.path]
        ) { [weak self] values in self?.addWorktree(at: values[1], branch: values[0]) }
    }

    /// A branch checked out nowhere: a new worktree beside the repository with that branch.
    func newWorktreeFor(branch: String) {
        guard let root = model.snapshot?.root else { return }
        let folder = root.lastPathComponent + "-" + branch.replacingOccurrences(of: "/", with: "-")
        prompt(
            String(localized: "New worktree"), labels: [String(localized: "Directory")],
            defaults: [root.deletingLastPathComponent().appendingPathComponent(folder).path]
        ) { [weak self] values in self?.addWorktree(at: values[0], branch: branch) }
    }

    private func addWorktree(at path: String, branch: String) {
        model.perform(String(localized: "Create worktree")) {
            try await $0.addWorktree(
                path: TypedPath.url(path), branch: branch)
        }
    }

    @objc func copyCommit() {
        guard let commit = model.selectedCommit, let pasteboard = system?.pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(commit.id, forType: .string)
    }

    /// Repository › Open on GitHub (⇧⌘G): the current remote's web page.
    @objc func openRemote() { system?.openWebPage(RemotePage.repository(model.snapshot)) }

    @objc func manageRemotes() {
        guard model.snapshot != nil, !model.isMutating else { return }
        host?.showWindow()
        host?.repositoryController?.manageRemotes()
    }

    private func prompt(
        _ title: String, labels: [String], defaults values: [String], action: @escaping @MainActor ([String]) -> Void
    ) {
        host?.prompt(title, labels: labels, defaults: values, button: String(localized: "Create"), action: action)
    }
}
