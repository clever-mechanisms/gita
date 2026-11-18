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
        providerPage.onChooseAccount = { [weak self] login in self?.model.chooseGitHubAccount(login) }
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
        codePane.diffView.onHunkSelection = { [weak self] in self?.updateCodePane() }
        codePane.onApplyHunk = { [weak self] in self?.applyHunk() }
        filePane.tree.onSelect = { [weak self] entry in self?.model.selectTreeEntry(entry) }
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
        codePane.diffView.update(
            model.diff, loading: model.isDiffLoading, blob: model.diffIsBlob,
            emptyMessage: codePaneState.emptyMessage, path: model.diffPath)
    }

    func rebuildCommitDetail() {
        let commit = model.selectedCommit
        let signals = model.signals(for: commit)
        let production = ProviderSignalQuery(signals: model.allSignals).production
        let details = model.commitDetails?.commit.id == commit?.id ? model.commitDetails : nil
        commitDetail.update(
            .init(
                commit: commit, message: details?.message, committer: details?.committer, stash: model.selectedStash,
                signals: signals, production: signals.contains { $0.kind == .deployment } ? production : nil,
                vercel: model.vercelContext, productionBehind: model.productionBehind,
                productionBranch: model.productionBranch, vercelSignals: model.vercelSignals,
                vercelDashboard: model.vercelDashboard))
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
                hasSelectedHunk: diff.selectedHunk != nil && diff.reviewedText == model.diff))
    }

    func updateCodePane() { codePane.apply(codePaneState) }

    func applyHunk() {
        guard codePane.hunkButton.isEnabled, let file = model.selectedFile, let index = codePane.diffView.selectedHunk
        else { return }
        let text = codePane.diffView.reviewedText
        let staged = model.staged
        let stagedBase = staged ? amend.source?.baseTree : nil
        if staged && stagedBase != nil { amendUnstagedPaths.insert(file.path) }
        model.perform(staged ? String(localized: "Unstage hunk") : String(localized: "Stage hunk")) {
            try await $0.applyHunk(
                path: file.path, staged: staged, expectedDiff: text, hunkIndex: index, stagedBase: stagedBase)
        }
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
