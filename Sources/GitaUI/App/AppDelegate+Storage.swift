import AppKit
import GitaCore

/// Per-repository inline Storage & Health routing and global Workspace Storage window wiring.
extension AppDelegate {
    @objc func showStorageInspector() {
        openInlineStorage(scope: .repository)
    }

    @objc func showRepositoryHealth() {
        openInlineStorage(scope: .health)
    }

    @objc func showWorkspaceStorage() {
        statusItem?.closePanel()
        var context = storageWindowContext(repositoryRoot: nil)
        context.onOpenRepository = { [weak self] url in
            self?.inspectStorage(at: url)
        }
        storageWindowController.show(context: context)
    }

    func inspectStorage(at root: URL) {
        statusItem?.closePanel()
        guard showRepositoryTab(root) else { return }
        let controller = openTabController(for: root) ?? repositoryController
        controller?.openToolPage(.storage(scope: .repository))
    }

    func invalidateStorage(repositoryRoot root: URL) {
        environment.storageStore.invalidate(repositoryRoot: root)
        storageWindowController.reloadIfVisible()
        openTabController(for: root)?.reloadInlineStorageIfVisible()
    }

    func cachedStorageSize(for root: URL) -> String? {
        environment.storageStore.state(for: root).report.map {
            StoragePresenter().formatBytes($0.totalAllocatedBytes)
        }
    }

    func storageWindowContext(repositoryRoot: URL?) -> StorageWindowContext {
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

    private func openInlineStorage(scope: StorageInlineViewController.Scope) {
        statusItem?.closePanel()
        guard (tabsController?.selectedRepository ?? model.snapshot?.root) != nil else {
            if scope == .repository {
                showWorkspaceStorage()
            } else {
                environment.system.beep()
            }
            return
        }
        showWindow()
        repositoryController?.openToolPage(.storage(scope: scope))
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
