import AppKit
import GitaCore

/// Shared confirmation sheets and mutation execution for per-repository Storage & Health surfaces.
@MainActor
final class StorageActionCoordinator {
    private let store: StorageStore
    private let windowProvider: () -> NSWindow?
    private let contextProvider: () -> StorageWindowContext
    private let checkedProvider: () -> Set<String>
    private let onDidMutate: () -> Void

    init(
        store: StorageStore,
        windowProvider: @escaping () -> NSWindow?,
        contextProvider: @escaping () -> StorageWindowContext,
        checkedProvider: @escaping () -> Set<String>,
        onDidMutate: @escaping () -> Void
    ) {
        self.store = store
        self.windowProvider = windowProvider
        self.contextProvider = contextProvider
        self.checkedProvider = checkedProvider
        self.onDidMutate = onDidMutate
    }

    func perform(_ action: StorageHealthAction, root: URL) {
        guard let window = windowProvider() else {
            executeHealthAction(action, root: root)
            return
        }
        presentOrExecuteHealthAction(action, root: root, on: window)
    }

    private func presentOrExecuteHealthAction(_ action: StorageHealthAction, root: URL, on window: NSWindow) {
        switch action {
        case .garbageCollection:
            confirmGarbageCollection(root: root, on: window) { [weak self] resolved in
                self?.executeHealthAction(resolved, root: root)
            }
        case .replaceCustomFSMonitor(let hook):
            confirmReplaceFSMonitor(hook: hook, on: window) { [weak self] in
                self?.executeHealthAction(action, root: root)
            }
        default:
            executeHealthAction(action, root: root)
        }
    }

    private func executeHealthAction(_ action: StorageHealthAction, root: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.perform(action, in: root)
            self.onDidMutate()
        }
    }

    private func confirmGarbageCollection(
        root: URL, on window: NSWindow, execute: @escaping (StorageHealthAction) -> Void
    ) {
        let active = hasActiveAgentForHealth(root: root)
        let resolved = StorageHealthAction.garbageCollection(pruneNow: !active)
        let detail =
            active
            ? String(
                localized: "An agent is active here. Git will run safe GC using its default prune grace period.")
            : String(localized: "Git will immediately prune unreachable objects in this repository.")
        DestructiveConfirmation(
            message: String(localized: "Run garbage collection?"), detail: detail, action: resolved.title
        ).present(on: window) { execute(resolved) }
    }

    private func hasActiveAgentForHealth(root: URL) -> Bool {
        let snapshot: RepositoryHealthSnapshot? =
            if case .loaded(let loaded) = store.healthState(for: root) { loaded } else { nil }
        return StoragePresenter().hasActiveAgent(
            in: root, snapshot: snapshot, report: store.state(for: root).report,
            activeAgentPaths: contextProvider().activeAgentPaths)
    }

    private func confirmReplaceFSMonitor(
        hook: String, on window: NSWindow, confirmed: @escaping @MainActor () -> Void
    ) {
        DestructiveConfirmation(
            message: String(localized: "Replace custom filesystem monitor?"),
            detail: String(
                localized:
                    "This will overwrite core.fsmonitor (\(hook)) with Git’s built-in filesystem monitor in local config."
            ),
            action: String(localized: "Replace")
        ).present(on: window, confirmed: confirmed)
    }

    func confirmRemoval(_ tree: CheckoutStorageReport, report: RepositoryStorageReport) {
        guard let window = windowProvider(), isRemovableWorktree(tree) else { return }
        let detail = removalDetail(for: tree, report: report)
        DestructiveConfirmation(
            message: String(localized: "Remove \(tree.displayName)?"), detail: detail,
            action: String(localized: "Remove Worktree")
        ).present(on: window) { [weak self] in
            self?.executeWorktreeRemoval(tree, report: report)
        }
    }

    private func isRemovableWorktree(_ tree: CheckoutStorageReport) -> Bool {
        !tree.isMainWorktree && !tree.isBare && !tree.isLocked
    }

    private func removalDetail(for tree: CheckoutStorageReport, report: RepositoryStorageReport) -> String {
        let warning = StoragePresenter().outlineNodes(
            for: report, activeAgentPaths: contextProvider().activeAgentPaths, now: Date()
        ).first { $0.checkout?.id == tree.id }?.warning
        return [tree.path.path, warning].compactMap { $0 }.joined(separator: "\n")
    }

    private func executeWorktreeRemoval(_ tree: CheckoutStorageReport, report: RepositoryStorageReport) {
        if contextProvider().onRemoveWorktree?(report.mainRoot, tree.worktree) == true { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.removeWorktree(tree.worktree, in: report.mainRoot)
            self.onDidMutate()
        }
    }

    func confirmTrash(_ report: RepositoryStorageReport, entry: HeavyFolderEntry?) {
        guard let window = windowProvider(), !store.actionState(for: report.mainRoot).isRunning else { return }
        let plan = StoragePresenter().trashPlan(
            report: report, entry: entry, checked: checkedProvider(),
            activeAgentPaths: contextProvider().activeAgentPaths)
        presentTrashPlan(plan, repository: report.mainRoot, on: window)
    }

    private func presentTrashPlan(_ plan: StorageTrashPlan, repository: URL, on window: NSWindow) {
        guard !plan.paths.isEmpty else {
            if plan.skippedActiveCount > 0 { showSkippedActiveAlert(on: window) }
            return
        }
        let message = trashConfirmationTitle(count: plan.paths.count)
        let detail = trashConfirmationDetail(for: plan)
        let groups = plan.groups.map { ($0.checkout, $0.entries) }
        DestructiveConfirmation(message: message, detail: detail, action: String(localized: "Move to Trash"))
            .present(on: window) { [weak self] in
                self?.executeTrash(groups, repository: repository)
            }
    }

    private func executeTrash(_ groups: [(URL, [HeavyFolderEntry])], repository: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.moveToTrash(groups, repository: repository)
            self.onDidMutate()
        }
    }

    private func showSkippedActiveAlert(on window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Active checkouts skipped")
        alert.informativeText = String(
            localized:
                "Active-agent checkouts are skipped by bulk cleanup. Select folders explicitly to Trash them.")
        alert.beginSheetModal(for: window)
    }

    private func trashConfirmationTitle(count: Int) -> String {
        count == 1 ? String(localized: "Move 1 folder to Trash?") : String(localized: "Move \(count) folders to Trash?")
    }

    private func trashConfirmationDetail(for plan: StorageTrashPlan) -> String {
        let agentNote = DestructiveConfirmation.workingAgentsNote(plan.activeAgentNames)
        let skippedNote =
            plan.skippedActiveCount > 0 ? String(localized: "Skipped checkouts with active agents.") : nil
        return [DestructiveConfirmation.pathList(plan.paths), agentNote, skippedNote]
            .compactMap { $0 }.joined(separator: "\n\n")
    }
}
