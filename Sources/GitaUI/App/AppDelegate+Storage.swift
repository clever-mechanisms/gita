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
        return StorageWindowContext(
            repositoryRoot: resolvedRoot,
            knownRepositories: known,
            activeAgentPaths: activeAgentWorktreePaths(),
            onRemoveWorktree: { [weak self] mainRoot, tree in
                guard let self, let controller = self.openTabController(for: mainRoot) else { return false }
                return controller.performConfirmedWorktreeRemoval(tree, repositoryRoot: mainRoot)
            },
            onOpenRepository: { [weak self] url in
                self?.openRepositoryTab(url)
            }
        )
    }

    private func activeAgentWorktreePaths() -> Set<String> {
        var paths = Set(
            WindowAgents.shared.sessions
                .filter { $0.state == .working }
                .map { ($0.checkoutRoot ?? $0.workingDirectory).path })
        for signal in model.allSignals where signal.kind == .agent && signal.state == .running {
            if let path = signal.worktreePath { paths.insert(path) }
        }
        return paths
    }
}
