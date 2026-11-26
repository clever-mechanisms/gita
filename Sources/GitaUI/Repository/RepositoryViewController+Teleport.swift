import AppKit
import GitaCore

/// Spacebar Quick Look floating preview for History commits, Local Changes / Commit files, and Stashes.
extension RepositoryViewController {
    static var sharedTeleportFacadeProvider: ((_ createIfNeeded: Bool) -> TeleportFacade?)?
    private static var fallbackTeleportFacade: TeleportFacade?

    var quickLookFacade: TeleportFacade {
        if let shared = Self.sharedTeleportFacadeProvider?(true) { return shared }
        if let existing = Self.fallbackTeleportFacade { return existing }
        let created = TeleportFacade(configDirectories: .system)
        Self.fallbackTeleportFacade = created
        return created
    }

    private var existingQuickLookFacade: TeleportFacade? {
        Self.sharedTeleportFacadeProvider?(false) ?? Self.fallbackTeleportFacade
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
        guard let facade = existingQuickLookFacade, facade.isQuickLookVisible,
            let target = currentQuickLookTarget()
        else { return }
        facade.updateQuickLookSelection(target)
    }

    func closeQuickLook() {
        existingQuickLookFacade?.closeQuickLook()
    }

    private func toggleHistoryQuickLook() {
        guard let target = commitQuickLookTarget() else { return }
        bindQuickLookCallbacks(kind: .history)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func toggleCommitFileQuickLook() {
        guard let root = model.snapshot?.root, let file = model.selectedFile else { return }
        let target = commitFileTarget(file, root: root)
        bindQuickLookCallbacks(kind: .file(.commit))
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func commitFileTarget(_ file: FileChange, root: URL) -> QuickLookTarget {
        let sha = model.selectedCommit?.id
        let status = file.indexCode != .unmodified ? file.indexCode : file.worktreeCode
        return .changedFile(
            repoPath: root, path: file.path, staged: false, statusCode: status, commitSHA: sha)
    }

    private func toggleChangedFileQuickLook(staged: Bool) {
        guard let root = model.snapshot?.root, let file = model.selectedFile else { return }
        let status = staged ? file.indexCode : file.worktreeCode
        let target = QuickLookTarget.changedFile(
            repoPath: root, path: file.path, staged: staged, statusCode: status, commitSHA: nil)
        bindQuickLookCallbacks(kind: .file(staged ? .staged : .unstaged))
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
    }

    private func toggleStashQuickLook() -> Bool {
        guard let root = model.snapshot?.root, let stash = model.selectedStash else { return false }
        let target = QuickLookTarget.stash(repoPath: root, ref: stash.ref, message: stash.subject)
        bindQuickLookCallbacks(kind: .stash)
        quickLookFacade.toggleQuickLook(for: target, relativeTo: view.window)
        return true
    }

    private enum QuickLookFileKind { case commit, unstaged, staged }
    private enum QuickLookSourceKind {
        case history
        case file(QuickLookFileKind)
        case stash
    }

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
        let delta = direction.offset
        switch kind {
        case .history: stepHistoryQuickLook(by: delta)
        case .file(let fileKind): stepFileQuickLook(kind: fileKind, by: delta)
        case .stash: stepStashQuickLook(by: delta)
        }
    }

    private func stepHistoryQuickLook(by delta: Int) {
        let commits = historyTable.commits
        guard let commit = adjacent(in: commits, selected: model.selectedCommit?.id, key: \.id, delta: delta)
        else { return }
        model.select(commit)
        if let target = commitQuickLookTarget() { quickLookFacade.updateQuickLookSelection(target) }
    }

    private func adjacent<Item, Key: Equatable>(
        in items: [Item], selected: Key?, key: KeyPath<Item, Key>, delta: Int
    ) -> Item? {
        let current = items.firstIndex { $0[keyPath: key] == selected } ?? 0
        let next = current + delta
        return items.indices.contains(next) ? items[next] : nil
    }

    private func files(for kind: QuickLookFileKind) -> [FileChange] {
        switch kind {
        case .commit: model.files
        case .unstaged: model.snapshot?.changes.filter(\.isUnstaged) ?? []
        case .staged: model.snapshot?.changes.filter(\.isStaged) ?? []
        }
    }

    private func stepFileQuickLook(kind: QuickLookFileKind, by delta: Int) {
        guard let root = model.snapshot?.root,
            let file = adjacent(in: files(for: kind), selected: model.selectedFile?.path, key: \.path, delta: delta)
        else { return }
        let target: QuickLookTarget
        if kind == .commit {
            model.selectFile(file)
            target = commitFileTarget(file, root: root)
        } else {
            let staged = kind == .staged
            chooseChange(file, staged: staged)
            target = .changedFile(
                repoPath: root, path: file.path, staged: staged,
                statusCode: staged ? file.indexCode : file.worktreeCode, commitSHA: nil)
        }
        quickLookFacade.updateQuickLookSelection(target)
    }

    private func stepStashQuickLook(by delta: Int) {
        guard let snapshot = model.snapshot,
            let stash = adjacent(in: snapshot.stashes, selected: model.selectedStash?.ref, key: \.ref, delta: delta)
        else { return }
        model.selectStash(stash)
        quickLookFacade.updateQuickLookSelection(
            .stash(repoPath: snapshot.root, ref: stash.ref, message: stash.subject))
    }

    private func openQuickLookTargetInMainWindow(_ target: QuickLookTarget) {
        view.window?.makeKeyAndOrderFront(nil)
        switch target {
        case .commit(_, let sha, _):
            model.section = .history
            showCommit(id: sha)
        case .changedFile(_, let path, let staged, _, let commitSHA):
            openQuickLookFile(path, staged: staged, commitSHA: commitSHA)
        case .stash(_, let ref, _):
            selectQuickLookStash(ref)
        }
    }

    private func selectQuickLookStash(_ ref: String) {
        if let stash = model.snapshot?.stashes.first(where: { $0.ref == ref }) { model.selectStash(stash) }
    }

    private func openQuickLookFile(_ path: String, staged: Bool, commitSHA: String?) {
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

extension QuickLookNavigationDirection {
    fileprivate var offset: Int { self == .next ? 1 : -1 }
}
