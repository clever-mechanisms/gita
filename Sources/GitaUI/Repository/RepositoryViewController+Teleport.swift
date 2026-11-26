import AppKit
import GitaCore

/// Spacebar Quick Look floating preview for History commits, Local Changes / Commit files, and Stashes.
extension RepositoryViewController {
    static weak var sharedTeleportFacade: TeleportFacade?
    private static var fallbackTeleportFacade: TeleportFacade?

    var quickLookFacade: TeleportFacade {
        if let shared = Self.sharedTeleportFacade { return shared }
        if let existing = Self.fallbackTeleportFacade { return existing }
        let created = TeleportFacade(configDirectories: .system)
        Self.fallbackTeleportFacade = created
        return created
    }

    func wireQuickLook() {
        historyTable.table.onSpace = { [weak self] in self?.toggleHistoryQuickLook() }
        filePane.commitFiles.outline.onSpace = { [weak self] in self?.toggleCommitFileQuickLook() }
        filePane.unstaged.list.outline.onSpace = { [weak self] in self?.toggleChangedFileQuickLook(staged: false) }
        filePane.staged.list.outline.onSpace = { [weak self] in self?.toggleChangedFileQuickLook(staged: true) }
        sidebarView.repositoryPane.list.table.onSpace = { [weak self] in
            self?.toggleStashQuickLook() ?? false
        }
    }

    func syncQuickLookSelection() {
        let facade = quickLookFacade
        guard facade.isQuickLookVisible, let target = currentQuickLookTarget() else { return }
        facade.updateQuickLookSelection(target)
    }

    func closeQuickLook() {
        quickLookFacade.closeQuickLook()
    }

    private func toggleHistoryQuickLook() {
        guard let target = commitQuickLookTarget() else { return }
        bindQuickLookCallbacks(kind: .history)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func toggleCommitFileQuickLook() {
        guard let root = model.snapshot?.root, let file = model.selectedFile else { return }
        let sha = model.selectedCommit?.id
        let status = file.indexCode != .unmodified ? file.indexCode : file.worktreeCode
        let target = QuickLookTarget.changedFile(
            repoPath: root, path: file.path, staged: false, statusCode: status, commitSHA: sha)
        bindQuickLookCallbacks(kind: .commitFile)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func toggleChangedFileQuickLook(staged: Bool) {
        guard let root = model.snapshot?.root, let file = model.selectedFile else { return }
        let status = staged ? file.indexCode : file.worktreeCode
        let target = QuickLookTarget.changedFile(
            repoPath: root, path: file.path, staged: staged, statusCode: status, commitSHA: nil)
        bindQuickLookCallbacks(kind: staged ? .stagedFile : .unstagedFile)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func toggleStashQuickLook() -> Bool {
        guard let root = model.snapshot?.root, let stash = model.selectedStash else { return false }
        let target = QuickLookTarget.stash(repoPath: root, ref: stash.ref, message: stash.subject)
        bindQuickLookCallbacks(kind: .stash)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
        return true
    }

    private enum QuickLookSourceKind { case history, commitFile, unstagedFile, stagedFile, stash }

    private func bindQuickLookCallbacks(kind: QuickLookSourceKind) {
        let facade = quickLookFacade
        facade.onQuickLookNavigate = { [weak self] direction in
            self?.stepQuickLookSelection(kind: kind, direction: direction)
        }
        facade.onQuickLookOpenFull = { [weak self] target in
            self?.openQuickLookTargetInMainWindow(target)
        }
    }

    private func stepQuickLookSelection(kind: QuickLookSourceKind, direction: QuickLookNavigationDirection) {
        let delta = direction == .next ? 1 : -1
        switch kind {
        case .history:
            let commits = historyTable.commits
            guard !commits.isEmpty else { return }
            let current = model.selectedCommit.flatMap { id in commits.firstIndex(where: { $0.id == id.id }) } ?? 0
            let nextIndex = min(max(0, current + delta), commits.count - 1)
            guard nextIndex != current else { return }
            model.select(commits[nextIndex])
            if let target = commitQuickLookTarget() { quickLookFacade.updateQuickLookSelection(target) }
        case .commitFile, .unstagedFile, .stagedFile:
            let list: [FileChange] =
                switch kind {
                case .commitFile: model.files
                case .unstagedFile: model.snapshot?.changes.filter(\.isUnstaged) ?? []
                case .stagedFile: model.snapshot?.changes.filter(\.isStaged) ?? []
                default: []
                }
            guard !list.isEmpty, let root = model.snapshot?.root else { return }
            let current = model.selectedFile.flatMap { f in list.firstIndex(where: { $0.path == f.path }) } ?? 0
            let nextIndex = min(max(0, current + delta), list.count - 1)
            guard nextIndex != current else { return }
            let file = list[nextIndex]
            let staged = kind == .stagedFile
            if kind == .commitFile {
                model.selectFile(file)
            } else {
                chooseChange(file, staged: staged)
            }
            let sha = kind == .commitFile ? model.selectedCommit?.id : nil
            let status =
                kind == .commitFile
                ? (file.indexCode != .unmodified ? file.indexCode : file.worktreeCode)
                : (staged ? file.indexCode : file.worktreeCode)
            quickLookFacade.updateQuickLookSelection(
                .changedFile(repoPath: root, path: file.path, staged: staged, statusCode: status, commitSHA: sha))
        case .stash:
            let stashes = model.snapshot?.stashes ?? []
            guard !stashes.isEmpty, let root = model.snapshot?.root else { return }
            let current = model.selectedStash.flatMap { s in stashes.firstIndex(where: { $0.ref == s.ref }) } ?? 0
            let nextIndex = min(max(0, current + delta), stashes.count - 1)
            guard nextIndex != current else { return }
            let stash = stashes[nextIndex]
            model.selectStash(stash)
            quickLookFacade.updateQuickLookSelection(
                .stash(repoPath: root, ref: stash.ref, message: stash.subject))
        }
    }

    private func openQuickLookTargetInMainWindow(_ target: QuickLookTarget) {
        view.window?.makeKeyAndOrderFront(nil)
        switch target {
        case .commit(_, let sha, _):
            model.section = .history
            showCommit(id: sha)
        case .changedFile(_, let path, let staged, _, let commitSHA):
            if let commitSHA {
                model.section = .history
                showCommit(id: commitSHA)
                if let file = model.files.first(where: { $0.path == path }) { model.selectFile(file) }
            } else {
                model.section = .changes
                if let file = model.snapshot?.changes.first(where: { $0.path == path }) {
                    chooseChange(file, staged: staged)
                }
            }
        case .stash(_, let ref, _):
            if let stash = model.snapshot?.stashes.first(where: { $0.ref == ref }) { model.selectStash(stash) }
        }
    }

    private func currentQuickLookTarget() -> QuickLookTarget? {
        if let stash = model.selectedStash, let root = model.snapshot?.root {
            return .stash(repoPath: root, ref: stash.ref, message: stash.subject)
        }
        if model.section == .changes, let root = model.snapshot?.root, let file = model.selectedFile {
            let status = model.staged ? file.indexCode : file.worktreeCode
            return .changedFile(
                repoPath: root, path: file.path, staged: model.staged, statusCode: status, commitSHA: nil)
        }
        return commitQuickLookTarget()
    }

    private func commitQuickLookTarget() -> QuickLookTarget? {
        guard let root = model.snapshot?.root, let commit = model.selectedCommit else { return nil }
        let signals = model.signals(for: commit)
        let pr = signals.first { $0.kind == .pullRequest }
        let ci = signals.first { $0.kind == .workflowRun }
        let hint = CommitHint(
            subject: commit.subject, author: commit.author, date: commit.date,
            prTitle: pr?.title, prState: pr?.state, ciState: ci?.state)
        return .commit(repoPath: root, sha: commit.id, metadata: hint)
    }
}
