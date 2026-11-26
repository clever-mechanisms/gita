import AppKit
import GitaCore

/// Storage Inspector, Bloat Cleaner, and Repository Health & Maintenance window wiring.
extension AppDelegate {
    @objc func showStorageInspector() {
        openStorageWindow(repositoryRoot: nil, scope: .repository)
    }

    @objc func showRepositoryHealth() {
        openStorageWindow(repositoryRoot: nil, scope: .health)
    }

    func inspectStorage(at root: URL) {
        openStorageWindow(repositoryRoot: root, scope: .repository)
    }

    func invalidateStorage(repositoryRoot root: URL) {
        environment.storageStore.invalidate(repositoryRoot: root)
        storageWindowController.reloadIfVisible()
    }

    private func openStorageWindow(repositoryRoot: URL?, scope: StorageWindowController.Scope) {
        statusItem?.closePanel()
        let context = storageWindowContext(repositoryRoot: repositoryRoot)
        storageWindowController.show(context: context, scope: scope)
    }

    private func storageWindowContext(repositoryRoot: URL?) -> StorageWindowContext {
        let resolvedRoot = repositoryRoot ?? tabsController?.selectedRepository ?? model.snapshot?.root
        let known =
            openRepositoryRoots
            + Preference.recentRepositories.strings(defaults).map { URL(fileURLWithPath: $0, isDirectory: true) }
        var activeAgents = Set(
            WindowAgents.shared.sessions
                .filter { $0.state == .working }
                .compactMap { ($0.checkoutRoot ?? $0.workingDirectory).path })
        for signal in model.allSignals where signal.kind == .agent && signal.state == .running {
            if let path = signal.worktreePath { activeAgents.insert(path) }
        }
        return StorageWindowContext(
            repositoryRoot: resolvedRoot,
            knownRepositories: known,
            activeAgentPaths: activeAgents,
            onRemoveWorktree: { [weak self] _, tree in
                self?.repositoryController?.removeWorktree(tree)
            },
            onOpenRepository: { [weak self] url in
                self?.openRepositoryTab(url)
            }
        )
    }
}
