import AppKit
import GitaCore

/// §6b Multi-commit compare, bulk actions (`Cherry-pick N…`, `Revert N…`, `Copy SHAs`, `Squash…`), and
/// Working Changes detail layout inside All Commits.
extension RepositoryViewController {
    func wireHistoryPower() {
        wireHistoryHeaderActions()
        commitDetail.compareView.onSwap = { [weak self] in self?.model.swapCompareCommits() }
        commitDetail.compareView.onSelectFile = { [weak self] file in self?.model.selectCompareFile(file) }
        historyMenu.multiCommitItems = { [weak self] in self?.multiCommitMenuItems() ?? [] }
    }

    func wireHistoryHeaderActions() {
        historyControls.onSelectCurrentBranch = { [weak self] in self?.selectCurrentBranchScope() }
        historyControls.onSelectBranch = { [weak self] ref in
            self?.model.focusHistory(on: ref)
            self?.rebuildSidebar()
        }
        historyControls.onSelectAuthor = { [weak self] author in
            self?.model.setAuthorFilter(author, mode: .highlight)
        }
        historyControls.onOpenAuthorTab = { [weak self] author in
            guard let self, let root = self.model.snapshot?.root else { return }
            self.commands?.openAuthorTab(author, in: root)
        }
        historyControls.onToggleAuthorMode = { [weak self] in self?.model.toggleAuthorFilterMode() }
        historyControls.onClearSearch = { [weak self] in self?.clearHistorySearchFilter() }
        historyTable.workingChangesRow.onSelect = { [weak self] in self?.openWorkingChangesDetail() }
        historyTable.workingChangesRow.onCommit = { [weak self] in self?.focusWorkingChangesComposer() }
    }

    func updateWorkingChangesBanner() {
        let state = WorkingChangesRowState(
            .init(
                snapshot: model.snapshot,
                displayedCommits: model.displayedCommits,
                graphs: model.focusedReference != nil ? model.focusedGraph : model.graph,
                isSearching: model.isSearchingHistory,
                isAuthorFiltering: model.inlineAuthor != nil || model.authorLens != nil,
                focusedReference: model.focusedReference,
                branchFilters: model.branchFilters,
                isSelected: model.isReviewingWorkingChanges))
        historyTable.updateWorkingChanges(state)
    }

    func openWorkingChangesDetail() {
        historyTable.select(nil as String?)
        if !model.showsHistoryDetails { model.toggleHistoryDetails() }
        model.selectWorkingChanges()
        syncHistoryDetailOverlay()
    }

    func focusWorkingChangesComposer() {
        openWorkingChangesDetail()
        view.window?.makeFirstResponder(commitFooter.field)
    }

    func scheduleHistoryDetailOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.syncHistoryDetailOverlay()
        }
    }

    func syncHistoryDetailOverlay() {
        guard model.section == .history else { return }
        if model.isReviewingWorkingChanges {
            applyWorkingChangesDetailOverlay()
            return
        }
        commitFooter.isHidden = true
        switch model.historySelection {
        case .pair:
            if detailTab != .commit { selectDetailTab(.commit) }
            if let compare = model.compareState {
                commitDetail.isHidden = false
                filesSplit.isHidden = true
                commitDetail.showCompare(compare, service: model.service, repositoryRoot: model.snapshot?.root)
            }
        case .many(let ids):
            if detailTab != .commit { selectDetailTab(.commit) }
            commitDetail.isHidden = false
            filesSplit.isHidden = true
            let eligibility = MultiCommitActionEligibility(
                selectedIDs: ids, commits: historyCommits, head: model.snapshot?.head,
                canOperate: model.canStartOperation && !model.hasConflicts)
            commitDetail.showMultiCommit(
                eligibility: eligibility,
                actions: MultiCommitSummaryView.Actions(
                    onCherryPick: { [weak self] in self?.confirmMultiCherryPick(eligibility.replayOrder) },
                    onRevert: { [weak self] in self?.confirmMultiRevert(eligibility.revertOrder) },
                    onCopySHAs: { [weak self] in self?.copySelectedSHAs(eligibility.selectedCommits) },
                    onSquash: { [weak self] in self?.squashSelectedCommits(eligibility) }))
        case .none, .commit:
            commitDetail.clearOverlay()
        }
    }

    private func applyWorkingChangesDetailOverlay() {
        updateDetailBar()
        commitFooter.isHidden = false
        if filePane.content != .localChanges { filePane.show(.localChanges) }
        if filePane.needsChangesSplitPosition {
            DispatchQueue.main.async { [weak self] in self?.filePane.positionChangesSplit() }
        }
        let changes = model.snapshot?.changes ?? []
        if !hasRenderedChanges || renderedChanges != changes || renderedAmendStaging != model.amendStaging {
            hasRenderedChanges = true
            renderedChanges = changes
            renderedAmendStaging = model.amendStaging
            filePane.showChanges(changes, amendStaging: model.amendStaging)
        }
        updateCleanTreeContext()
        filePane.select(path: model.selectedFile?.path, staged: model.staged)
        filePane.updateStageButtons()
        updateCommitActions()
        refreshCommitSigningAndTemplateIfNeeded()
        loadRecentMessagesForWorkingOverlayIfNeeded()
    }

    private func loadRecentMessagesForWorkingOverlayIfNeeded() {
        guard commitFooter.recentMessages.isEmpty,
            let head = model.snapshot?.head,
            let service = model.service
        else { return }
        Task { [weak self] in
            let loaded = (try? await service.recentCommitMessages()) ?? []
            guard let self, self.model.service === service, self.model.snapshot?.head == head else { return }
            if self.commitFooter.recentMessages.isEmpty {
                self.commitFooter.recentMessages = loaded
            }
        }
    }

    func multiCommitMenuItems() -> [NSMenuItem] {
        switch model.historySelection {
        case .pair:
            let item = MenuAction(String(localized: "Swap Comparison"), symbol: "arrow.left.arrow.right") {
                [weak self] in self?.model.swapCompareCommits()
            }
            return [item]
        case .many(let ids):
            let eligibility = MultiCommitActionEligibility(
                selectedIDs: ids, commits: historyCommits, head: model.snapshot?.head,
                canOperate: model.canStartOperation && !model.hasConflicts)
            let count = eligibility.selectedCommits.count
            let cherryPick = MenuAction(String(localized: "Cherry-pick \(count)…"), symbol: "arrow.triangle.branch") {
                [weak self] in self?.confirmMultiCherryPick(eligibility.replayOrder)
            }
            cherryPick.isEnabled = eligibility.canCherryPick
            let revert = MenuAction(String(localized: "Revert \(count)…"), symbol: "arrow.uturn.backward") {
                [weak self] in self?.confirmMultiRevert(eligibility.revertOrder)
            }
            revert.isEnabled = eligibility.canRevert
            let squash = MenuAction(String(localized: "Squash…"), symbol: "square.stack.3d.down.right") {
                [weak self] in self?.squashSelectedCommits(eligibility)
            }
            squash.isEnabled = eligibility.canSquash
            let copy = MenuAction(String(localized: "Copy SHAs"), symbol: "doc.on.doc") { [weak self] in
                self?.copySelectedSHAs(eligibility.selectedCommits)
            }
            return [cherryPick, revert, squash, .separator(), copy]
        case .none, .commit:
            return []
        }
    }

    func copySelectedSHAs(_ commits: [GitCommit]) {
        guard !commits.isEmpty else { return }
        Deck.copy(commits.map(\.id).joined(separator: "\n"))
    }

    func confirmMultiCherryPick(_ commits: [GitCommit]) {
        guard !commits.isEmpty, model.canStartOperation, !model.hasConflicts,
            let window = view.window, window.attachedSheet == nil, let expectedService = model.service
        else { return }
        let title = String(localized: "Cherry-pick \(commits.count) commits?")
        let alert = SidebarDropMenuBuilder.multiCommitConfirmation(
            title: title, commits: commits, actionTitle: String(localized: "Cherry-pick \(commits.count)"))
        AlertPresenter.shared.present(alert, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.model.service === expectedService else { return }
            let ids = commits.map(\.id)
            self.model.performGitOperation(GitOperationKind.cherryPick.localizedTitle) { git in
                try await git.cherryPick(commits: ids)
            }
        }
    }

    func confirmMultiRevert(_ commits: [GitCommit]) {
        guard !commits.isEmpty, model.canStartOperation, !model.hasConflicts,
            let window = view.window, window.attachedSheet == nil, let expectedService = model.service
        else { return }
        let title = String(localized: "Revert \(commits.count) commits?")
        let alert = SidebarDropMenuBuilder.multiCommitConfirmation(
            title: title, commits: commits, actionTitle: String(localized: "Revert \(commits.count)"))
        AlertPresenter.shared.present(alert, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.model.service === expectedService else { return }
            let ids = commits.map(\.id)
            self.model.performGitOperation(GitOperationKind.revert.localizedTitle) { git in
                try await git.revert(commits: ids)
            }
        }
    }

    func squashSelectedCommits(_ eligibility: MultiCommitActionEligibility) {
        guard let base = eligibility.squashBase, !eligibility.squashPrefill.isEmpty else { return }
        view.window.map { RepositorySheetLauncher(model: model, coordinator: sheets, window: $0) }?
            .reviewInteractiveRebase(after: base, prefillActions: eligibility.squashPrefill)
    }

    func selectCurrentBranchScope() {
        guard let snapshot = model.snapshot else { return }
        if let branch = snapshot.branch,
            let ref = snapshot.references.first(where: { $0.kind == .branch && $0.name == branch })
        {
            model.focusHistory(on: ref)
            rebuildSidebar()
        } else if let head = snapshot.head {
            let ref = GitReference(name: String(head.prefix(7)), fullName: "HEAD", commit: head, kind: .branch)
            model.focusHistory(on: ref)
            rebuildSidebar()
        }
    }

    func clearHistorySearchFilter() {
        historyControls.search.stringValue = ""
        model.searchHistory("", field: model.searchField)
        updateHistoryScope()
        rebuildSidebar()
    }
}
