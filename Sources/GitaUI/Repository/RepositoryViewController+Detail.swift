import AppKit
import GitaCore

/// The detail pane under the history: the Commit tab, the file pane with the code pane, and the bar above them.
extension RepositoryViewController {
    func wireDetail() {
        providerPage.list.loader = detailLoader
        providerPage.list.makeReview = { [weak self] item in
            guard let root = self?.model.snapshot?.root else { return nil }
            return PullRequestReviewController.review(item, root: root)?.reviewView
        }
        providerPage.onRefresh = { [weak self] in
            guard let self else { return }
            if self.model.section != .deployments { self.model.readGitHubAccounts(again: true) }
            self.model.refreshProviders()
        }
        providerPage.onChooseAccount = { [weak self] account in self?.model.chooseGitHubAccount(account) }
        wirePullRequestWorkspace()
        commitDetail.loader = detailLoader
        commitDetail.onSelectCommit = { [weak self] id in self?.selectCommit(id: id) }
        commitDetail.onVercelAction = { [weak self] action, item in
            guard let self else { return }
            VercelActions.confirm(action, item: item, model: self.model)
        }
        commitDetail.onRolloutAction = { [weak self] action in
            guard let self else { return }
            VercelSignalText.confirm(action, model: self.model)
        }
        commitDetail.buildLogLoader = { [weak self] item in await self?.model.vercelBuildLog(item) }
        detailBar.onSelectTab = { [weak self] tab in self?.selectDetailTab(tab) }
        detailBar.onChooseParent = { [weak self] index in self?.model.compareWithParent(index) }
        detailBar.onApplyStash = { [weak self] in self?.applySelectedStash() }
        codePane.diffView.defaults = model.defaults
        codePane.diffView.preferredLayout = DiffPreference.layout(model.defaults)
        codePane.diffView.onHunkSelection = { [weak self] in self?.updateCodePane() }
        codePane.onApplyHunkAtIndex = { [weak self] index in self?.applyHunk(at: index) }
        codePane.onDiscardHunk = { [weak self] index in self?.discardHunk(at: index) }
        codePane.onStageLines = { [weak self] rows in self?.applyLines(rows: rows) }
        codePane.onDiscardLines = { [weak self] rows in self?.discardLines(rows: rows) }
        codePane.onDiffOptionsChanged = { [weak self] options in self?.model.setDiffOptions(options) }
        codePane.onOpenInEditor = { [weak self] line in self?.openInEditor(at: line) }
        codePane.diffView.onShowLineHistory = { [weak self] range in self?.openLineHistory(range: range) }
        codePane.diffView.onCopyPermalink = { [weak self] path, lines in
            self?.copyFilePermalink(path: path, revision: nil, lines: lines)
        }
        codePane.diffView.onOpenInExternalDiff = { [weak self] in self?.openInExternalDiffTool() }
        filePane.tree.onSelect = { [weak self] entry in
            self?.closeBlame()
            self?.model.selectTreeEntry(entry)
        }
        filePane.tree.onError = { [weak self] message in
            self?.model.log(String(localized: "Tree failed"), message, failed: true)
        }
        filePane.tree.menuProvider = { [weak self] entry in self?.treeEntryMenu(entry) }
    }

    /// The selected commit, stash or working-tree change in every part of the detail pane.
    func rebuildSelection() {
        let commit = model.selectedCommit
        historyTable.select(commit?.id)
        detailTab = DetailBarState.followingReview(
            detailTab, isTreeReview: model.isTreeReview, isHistory: model.section == .history)
        let isTree = model.isTreeReview && commit != nil && model.section == .history
        let isChanges = model.section == .changes
        filePane.show(isTree ? .tree : isChanges ? .localChanges : .commitFiles)
        if isChanges && filePane.needsChangesSplitPosition {
            DispatchQueue.main.async { [weak self] in self?.filePane.positionChangesSplit() }
        }
        filePane.tree.configure(
            service: isTree ? model.service : nil, commit: isTree && model.commitDetails != nil ? commit?.id : nil)
        detailBar.showParents(commit?.parents ?? [], comparing: model.comparisonBase)
        rebuildFileLists(isChanges: isChanges)
        selectShownFile()
        showDiff()
        rebuildCommitDetail()
        updateDetailBar()
    }

    private func rebuildFileLists(isChanges: Bool) {
        if isChanges {
            let changes = model.snapshot?.changes ?? []
            let amendStaging = model.amendStaging
            if !hasRenderedChanges || renderedChanges != changes || renderedAmendStaging != amendStaging {
                hasRenderedChanges = true
                renderedChanges = changes
                renderedAmendStaging = amendStaging
                filePane.showChanges(changes, amendStaging: amendStaging)
            }
            updateCleanTreeContext()
        } else if renderedFilesRevision != model.filesRevision {
            renderedFilesRevision = model.filesRevision
            filePane.showCommitFiles(model.files)
        }
    }

    /// Highlights the selected file in its list.
    func selectShownFile() {
        filePane.select(path: model.selectedFile?.path, staged: model.staged)
        filePane.updateStageButtons()
    }

    func showDiff() {
        let effectivePath = model.selectedTreePath ?? model.diffPath
        closeBlameIfFileSwitched(to: effectivePath)
        codePane.diffView.repositoryRoot = model.snapshot?.root
        codePane.displayDiffOptions(model.diffOptions)
        codePane.diffView.update(
            model.diff, loading: model.isDiffLoading, blob: model.diffIsBlob,
            emptyMessage: codePaneState.emptyMessage, path: effectivePath,
            binaryBlobByteCount: model.diffIsBlob ? model.binaryBlobByteCount : nil)
        guard let effectivePath else {
            mediaLoadTask?.cancel()
            mediaLoadTask = nil
            return
        }
        resolveMediaOrBinarySizesIfNeeded(
            text: model.diff, path: effectivePath, isBlob: model.diffIsBlob)
    }

    private func resolveMediaOrBinarySizesIfNeeded(text: String, path: String, isBlob: Bool) {
        if codePane.diffView.needsImageLoad(for: path) {
            loadImagePreview(text: text, path: path, isBlob: isBlob)
            return
        }
        guard !isBlob, BinaryDiffSummary.isBinaryDiff(text),
            !ImageFileFormat.isSupportedImagePath(path),
            let service = model.service
        else { return }
        mediaLoadTask?.cancel()
        mediaLoadTask = Task { [weak self] in
            let sizes = await service.binaryObjectSizes(in: text)
            guard let self, !Task.isCancelled, self.model.service === service,
                self.model.diffPath == path, self.model.diff == text
            else { return }
            self.codePane.diffView.updateBinarySizes(old: sizes.old, new: sizes.new, for: path)
        }
    }

    private func loadImagePreview(text: String, path: String, isBlob: Bool) {
        guard let service = model.service else {
            codePane.diffView.fallbackToBinaryEmpty(for: path)
            return
        }
        mediaLoadTask?.cancel()
        if isBlob {
            guard let commitID = model.selectedCommit?.id else {
                codePane.diffView.fallbackToBinaryEmpty(for: path)
                return
            }
            mediaLoadTask = Task { [weak self] in
                let asset = await ImageDiffLoader.loadBlob(service: service, commit: commitID, path: path)
                guard let self, !Task.isCancelled, self.model.service === service,
                    self.model.selectedTreePath == path, self.model.selectedCommit?.id == commitID
                else { return }
                self.codePane.diffView.updateImageDiff(old: nil, new: asset, for: path, isBlob: true)
            }
            return
        }
        let fileURL = codePane.diffView.existingFileURL(for: path)
        mediaLoadTask = Task { [weak self] in
            let loaded = await ImageDiffLoader.loadDiff(service: service, diffText: text, fileURL: fileURL)
            guard let self, !Task.isCancelled, self.model.service === service,
                self.model.diffPath == path, self.model.diff == text
            else { return }
            self.codePane.diffView.updateBinarySizes(old: loaded.oldByteCount, new: loaded.newByteCount, for: path)
            self.codePane.diffView.updateImageDiff(old: loaded.old, new: loaded.new, for: path, isBlob: false)
        }
    }

    func rebuildCommitDetail() {
        let commit = model.selectedCommit
        let signals = model.signals(for: commit)
        let production = ProviderSignalQuery(signals: model.allSignals).production
        let details = model.commitDetails?.commit.id == commit?.id ? model.commitDetails : nil
        commitDetail.update(
            .init(
                commit: commit, message: details?.message, committer: details?.committer,
                signature: commit.flatMap { commitSignatureCache[$0.id] }, stash: model.selectedStash,
                signals: signals, production: signals.contains { $0.kind == .deployment } ? production : nil,
                vercel: model.vercelContext, productionBehind: model.productionBehind,
                productionBranch: model.productionBranch, vercelSignals: model.vercelSignals,
                vercelDashboard: model.vercelDashboard))
        loadCommitSignatureIfNeeded(for: commit)
    }

    func selectDetailTab(_ tab: DetailTab) {
        detailTab = tab
        if tab != .commit, model.isTreeReview != (tab == .tree) { model.reviewTree(tab == .tree) }
        updateDetailBar()
    }

    func updateDetailBar() {
        let state = DetailBarState(
            tab: detailTab, isChanges: model.section == .changes, commit: model.selectedCommit,
            hasStash: model.selectedStash != nil)
        detailTab = state.tab
        detailBar.apply(state)
        commitDetail.isHidden = !state.showsCommitDetail
        filesSplit.isHidden = state.showsCommitDetail
    }

    var codePaneState: CodePaneState {
        let diff = codePane.diffView
        let noAmendFiles = if case .armed(_, _, let files) = model.amendStaging { files.isEmpty } else { true }
        return CodePaneState(
            .init(
                isChanges: model.section == .changes, isStaged: model.staged,
                path: model.selectedTreePath ?? model.selectedFile?.path, hasSelectedFile: model.selectedFile != nil,
                selectedFileIsConflict: model.selectedFile?.isConflict == true,
                hasSelectedTreePath: model.selectedTreePath != nil, hasCommit: model.selectedCommit != nil,
                isTreeReview: model.isTreeReview, hasFiles: !model.files.isEmpty,
                isWorkingTreeClean: model.snapshot?.changes.isEmpty == true && noAmendFiles,
                isMutating: model.isMutating,
                isDiffLoading: model.isDiffLoading,
                canApplyHunks: diff.document?.canApplyHunks == true,
                ignoreWhitespace: codePane.diffOptions.ignoreWhitespace))
    }

    func updateCodePane() { codePane.apply(codePaneState) }

    func applyHunk(at index: Int) {
        applyReviewedDiff(
            title: model.staged ? String(localized: "Unstage hunk") : String(localized: "Stage hunk")
        ) { service, path, staged, text, stagedBase, options in
            try await service.applyHunk(
                path: path, staged: staged, expectedDiff: text, hunkIndex: index, stagedBase: stagedBase,
                options: options)
        }
    }

    func discardHunk(at index: Int) {
        guard let file = model.selectedFile else { return }
        let lineCount = DiffDocumentBuilder.changedLineCount(in: codePane.diffView.currentLines, hunkIndex: index)
        let confirmation = CodePaneView.discardHunkConfirmation(path: file.path, lineCount: lineCount)
        discardReviewedDiff(title: String(localized: "Discard hunk"), confirmation: confirmation) {
            service, path, text, options in
            try await service.discardHunk(path: path, expectedDiff: text, hunkIndex: index, options: options)
        }
    }

    func applyLines(rows: IndexSet) {
        guard !rows.isEmpty else { return }
        applyReviewedDiff(
            title: model.staged ? String(localized: "Unstage lines") : String(localized: "Stage lines")
        ) { service, path, staged, text, stagedBase, options in
            try await service.applyLines(
                path: path, staged: staged, expectedDiff: text, selectedRows: rows, stagedBase: stagedBase,
                options: options)
        }
    }

    func discardLines(rows: IndexSet) {
        guard !rows.isEmpty, let file = model.selectedFile else { return }
        let confirmation = CodePaneView.discardLinesConfirmation(path: file.path, lineCount: rows.count)
        discardReviewedDiff(title: String(localized: "Discard lines"), confirmation: confirmation) {
            service, path, text, options in
            try await service.discardLines(path: path, expectedDiff: text, selectedRows: rows, options: options)
        }
    }

    private func applyReviewedDiff(
        title: String,
        action: @escaping @Sendable (GitService, String, Bool, String, String?, DiffOptions) async throws -> Void
    ) {
        let options = model.diffOptions
        guard codePaneState.canApplyDocumentHunks, !model.isMutating,
            let file = model.selectedFile,
            hasCurrentReviewedDiff(for: file.path)
        else { return }
        let text = codePane.diffView.reviewedText
        let staged = model.staged
        let stagedBase = staged ? amend.source?.baseTree : nil
        if staged && stagedBase != nil { amendUnstagedPaths.insert(file.path) }
        model.perform(title) {
            try await action($0, file.path, staged, text, stagedBase, options)
        }
    }

    private func discardReviewedDiff(
        title: String,
        confirmation: DestructiveConfirmation,
        action: @escaping @Sendable (GitService, String, String, DiffOptions) async throws -> Void
    ) {
        let options = model.diffOptions
        guard codePaneState.canApplyDocumentHunks, !model.isMutating, !model.staged,
            let file = model.selectedFile,
            let window = view.window,
            hasCurrentReviewedDiff(for: file.path)
        else { return }
        let expectedDiff = codePane.diffView.reviewedText
        AlertPresenter.shared.confirm(confirmation.alert(), on: window) { [weak self] in
            self?.model.perform(title) {
                try await action($0, file.path, expectedDiff, options)
            }
        }
    }

    private func hasCurrentReviewedDiff(for path: String) -> Bool {
        guard !codePane.diffView.reviewedText.isEmpty, codePane.diffView.shownPath == path else { return false }
        return codePane.diffView.reviewedText == model.diff
    }

    func openInEditor(at line: Int?, opener: AppOpener = .system) {
        guard let root = model.snapshot?.root,
            let path = model.selectedTreePath ?? model.selectedFile?.path ?? codePane.diffView.shownPath,
            OpenIn.editorApp(opener, defaults: model.defaults) != nil
        else { return }
        CodePaneView.openInEditor(
            root.appendingPathComponent(path), line: line, opener: opener, defaults: model.defaults)
    }

    func applySelectedStash() {
        guard let stash = model.selectedStash else { return }
        model.perform(String(localized: "Apply stash")) { try await $0.applyStash(ref: stash.ref) }
    }

    func reviewConflicts() {
        model.staged = false
        model.section = .changes
    }
}

extension RepositoryViewController: PullRequestReviewOpening {
    /// The Pull Requests page with the pull request expanded, its review in place.
    func openPullRequestReview(_ item: ProviderItem) { openProviderContext(item) }
}
