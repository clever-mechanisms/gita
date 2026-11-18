import AppKit
import GitaCore

/// Binds `ReferenceMenuBuilder` to this window's repository state and app commands.
extension RepositoryViewController {
    private var referenceMenuBuilder: ReferenceMenuBuilder? {
        guard let snapshot = model.snapshot else { return nil }
        let model = model
        return ReferenceMenuBuilder(
            snapshot: snapshot,
            canOperate: model.canStartOperation && !model.hasConflicts,
            isMutating: model.isMutating,
            filters: model.branchFilters,
            vercel: model.vercelContext,
            productionBranch: model.productionBranch,
            commits: historyCommits,
            commands: commands,
            target: nil,
            actions: ReferenceMenuActions(
                worktreeItems: { [weak self] path in
                    guard let checkout = self?.checkoutMenu(path: path, isMain: false) else { return [] }
                    let items = Array(checkout.items.prefix(3))
                    items.forEach(checkout.removeItem)
                    return items
                },
                reviewReference: { reference in
                    ReviewLauncher.menuItem(
                        model: model, scope: { try await $0.reviewScope(reference: reference.fullName) })
                },
                reviewCommit: { commit in
                    ReviewLauncher.menuItem(
                        commit: true, model: model, scope: { try await $0.reviewScope(commit: commit.id) })
                },
                toggleFilter: { kind, reference in model.toggleBranchFilter(kind, reference) },
                clearFilters: { model.clearBranchFilters() },
                openRemoteBranch: { [weak self] remoteRef in self?.openRemoteBranch(remoteRef) }
            )
        )
    }

    /// One item per reference on `commit`, each with its full menu.
    func referenceItems(for commit: GitCommit) -> [NSMenuItem] {
        referenceMenuBuilder?.referenceItems(for: commit, remoteNames: remoteReferenceNames) ?? []
    }

    /// A commit's own extra actions (New Branch, Check Out Detached, Review).
    func commitItems(for commit: GitCommit) -> [NSMenuItem] {
        referenceMenuBuilder?.commitItems(for: commit) ?? []
    }

    func referenceMenu(_ reference: GitReference) -> NSMenu? {
        referenceMenuBuilder?.menu(reference)
    }

    /// The "+N" pill on a history row: every reference on that commit, each with its menu.
    func showReferences(of commitID: String, rect: NSRect, in view: NSView) {
        guard
            let commit = historyCommits.first(where: { $0.id == commitID })
                ?? model.snapshot?.commits.first(where: { $0.id == commitID })
        else { return }
        let menu = NSMenu()
        referenceItems(for: commit).forEach(menu.addItem)
        guard !menu.items.isEmpty else { return }
        menu.popUp(
            positioning: nil, at: NSPoint(x: rect.minX, y: view.isFlipped ? rect.maxY + 2 : rect.minY - 2), in: view)
    }
}
