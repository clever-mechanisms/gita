import AppKit
import GitaCore

extension StorageWindowController {
    func perform(_ action: StorageHealthAction, root: URL) {
        let execute: (StorageHealthAction) -> Void = { [weak self] resolved in
            Task { @MainActor in
                guard let self else { return }
                await self.store.perform(resolved, in: root)
                self.reloadIfVisible()
            }
        }
        guard let window else {
            execute(action)
            return
        }
        switch action {
        case .garbageCollection:
            let snapshot: RepositoryHealthSnapshot?
            if case .loaded(let loaded) = store.healthState(for: root) {
                snapshot = loaded
            } else {
                snapshot = nil
            }
            let active = StoragePresenter().hasActiveAgent(
                in: root, snapshot: snapshot, report: store.state(for: root).report,
                activeAgentPaths: context.activeAgentPaths)
            let resolved = StorageHealthAction.garbageCollection(pruneNow: !active)
            let detail =
                active
                ? String(
                    localized:
                        "An agent is active here. Git will run safe GC using its default prune grace period."
                )
                : String(localized: "Git will immediately prune unreachable objects in this repository.")
            DestructiveConfirmation(
                message: String(localized: "Run garbage collection?"), detail: detail, action: resolved.title
            ).present(on: window) { execute(resolved) }
        case .replaceCustomFSMonitor(let hook):
            DestructiveConfirmation(
                message: String(localized: "Replace custom filesystem monitor?"),
                detail: String(
                    localized:
                        "This will overwrite core.fsmonitor (\(hook)) with Git’s built-in filesystem monitor in local config."
                ),
                action: String(localized: "Replace")
            ).present(on: window) { execute(action) }
        default:
            execute(action)
        }
    }

    func confirmRemoval(_ tree: CheckoutStorageReport, report: RepositoryStorageReport) {
        guard let window, !tree.isMainWorktree && !tree.isBare && !tree.isLocked else { return }
        if let remove = context.onRemoveWorktree {
            remove(report.mainRoot, tree.worktree)
            store.invalidate(repositoryRoot: report.mainRoot)
            return
        }
        let warning = StoragePresenter().outlineNodes(
            for: report, activeAgentPaths: context.activeAgentPaths,
            now: Date()
        ).first { $0.checkout?.id == tree.id }?.warning
        let detail = [tree.path.path, warning].compactMap { $0 }.joined(separator: "\n")
        DestructiveConfirmation(
            message: String(localized: "Remove \(tree.displayName)?"), detail: detail,
            action: String(localized: "Remove Worktree")
        ).present(on: window) { [weak self] in
            guard let self else { return }
            Task {
                await store.removeWorktree(tree.worktree, in: report.mainRoot)
                self.reloadIfVisible()
            }
        }
    }

    func confirmTrash(_ report: RepositoryStorageReport, entry: HeavyFolderEntry?) {
        guard let window, !store.actionState(for: report.mainRoot).isRunning else { return }
        let plan = StoragePresenter().trashPlan(
            report: report, entry: entry, checked: checked, activeAgentPaths: context.activeAgentPaths)
        let paths = plan.paths
        guard !paths.isEmpty else {
            if plan.skippedActiveCount > 0 {
                let alert = NSAlert()
                alert.messageText = String(localized: "Active checkouts skipped")
                alert.informativeText = String(
                    localized:
                        "Active-agent checkouts are skipped by bulk cleanup. Select folders explicitly to Trash them."
                )
                alert.beginSheetModal(for: window)
            }
            return
        }
        let message =
            paths.count == 1
            ? String(localized: "Move 1 folder to Trash?")
            : String(localized: "Move \(paths.count) folders to Trash?")
        let agentNote = DestructiveConfirmation.workingAgentsNote(plan.activeAgentNames)
        let skippedNote =
            plan.skippedActiveCount > 0
            ? String(localized: "Skipped checkouts with active agents.") : nil
        let detail = [DestructiveConfirmation.pathList(paths), agentNote, skippedNote]
            .compactMap { $0 }.joined(separator: "\n\n")
        let groups = plan.groups.map { ($0.checkout, $0.entries) }
        DestructiveConfirmation(message: message, detail: detail, action: String(localized: "Move to Trash"))
            .present(on: window) { [weak self] in
                guard let self else { return }
                Task {
                    await store.moveToTrash(groups, repository: report.mainRoot)
                    self.reloadIfVisible()
                }
            }
    }
}
