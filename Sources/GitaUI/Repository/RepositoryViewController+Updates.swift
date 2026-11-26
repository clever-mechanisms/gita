import AppKit
import GitaCore

/// Model changes: each kind of change refreshes the parts that show it, then the bars follow the model's state.
extension RepositoryViewController {
    func update(_ change: AppModel.Change) {
        guard isViewLoaded else { return }
        updating = true
        defer { updating = false }
        switch change {
        case .banner:
            syncContentBanner()
            return
        case .repository:
            repositoryChanged()
            scheduleHistoryDetailOverlay()
        case .history:
            filterHistory()
            refreshVelocitySparkline()
            rebuildSidebar()
        case .commitDraft: showCommitField()
        case .historyAppearance:
            applyHistoryAppearance()
            refreshVelocitySparkline()
        case .section:
            guard sectionChanged() else { return }
            scheduleHistoryDetailOverlay()
        case .selection:
            rebuildSelection()
            rebuildSidebar()
            syncQuickLookSelection()
        case .diff:
            showDiff()
            syncSmartDiff()
            syncReviewedHunks()
            selectShownFile()
        case .providers: providersChanged()
        case .activity: break
        case .status:
            refreshOverview()
            refreshStrip()
        }
        updateBars(after: change)
    }

    private func repositoryChanged() {
        closeQuickLook()
        resetReviewedHunks()
        model.loadTopAuthorsIfNeeded()
        if model.isReviewingWorkingChanges, model.snapshot?.changes.isEmpty != false, amend.source == nil {
            model.graphState.isReviewingWorkingChanges = false
            commitFooter.isHidden = true
        }
        reconcileAmend()
        showCommitField()
        commitEcosystemRepositoryChanged()
        syncBisectPresenter()
        sheets.repositoryChanged(to: model.service)
        historyControls.search.stringValue = model.searchQuery
        unpushed.update(model.snapshot)
        indexAgents()
        rebuildSidebar()
        filterHistory()
        refreshVelocitySparkline()
        rebuildSelection()
        refreshPage()
        refreshStrip()
        refreshOverview()
    }

    private func providersChanged() {
        historyTable.reloadSignals()
        rebuildSidebar()
        rebuildCommitDetail()
        refreshPage()
        refreshStrip()
        refreshOverview()
    }

    /// The section changed: false when it opened a window or the Agents pane instead (the page stays as it was).
    private func sectionChanged() -> Bool {
        let requested = model.section
        if requested != .changes && requested != .history { closeBlame() }
        switch SectionRoute(requested) {
        case .window(let section):
            // Settings, Connections, Activity and About are windows now: open it and keep showing the current page.
            Self.openWindow(for: section)
            restoreSection(after: requested)
            return false
        case .agentsPane:
            // Worktrees & Agents is the right-hand pane now (old deep links, notifications): open it, keep the page.
            showAgentsPane()
            restoreSection(after: requested)
            return false
        case .page(let section):
            showPage(section)
            return true
        }
    }

    private func restoreSection(after requested: Section) {
        let page = lastPageSection
        DispatchQueue.main.async { [weak self] in
            if self?.model.section == requested { self?.model.section = page }
        }
    }

    private func showPage(_ section: Section) {
        lastPageSection = section
        let panes = SectionPanes(section)
        historyPane.isHidden = !panes.showsHistoryPane
        pagePane.isHidden = panes.showsHistoryPane
        if section != .history { sidebarSelection = nil }
        commitFooter.isHidden = !panes.showsCommitFooter
        if section == .changes { refreshCommitSigningAndTemplateIfNeeded() }
        if panes.showsHistoryPane {
            updateHistoryScope()
            // A section switch changes no row content: reload the rows only when the zoom changed; the panes always
            // follow the section.
            if HistoryTableController.rowHeight(percent: model.historyZoomPercent) != historyTable.table.rowHeight {
                applyHistoryAppearance()
            } else {
                historyTable.relayoutColumns()
                historyTable.updateGraphWidth()
                historyTable.updateSignalColumn()
                arrangeSectionPanes()
            }
            rebuildSidebar()
            rebuildSelection()
            refreshStrip()
        } else {
            rebuildSidebar()
            providerPage.setZoom(percent: model.historyZoomPercent)
            refreshPage()
        }
    }

    static func openWindow(for section: Section) {
        switch section {
        case .connections: SettingsWindowController.shared.show(.integrations)
        case .activity: ActivityWindowController.shared.show(model: nil)
        case .about: AboutWindowController.shared.show()
        default: SettingsWindowController.shared.show()
        }
    }

    /// The bars and buttons that follow the model's state after any change.
    private func updateBars(after change: AppModel.Change) {
        updateRetryFooter()
        filePane.updateStageButtons()
        if model.section == .changes || model.isReviewingWorkingChanges { updateCleanTreeContext() }
        applyOperationBar()
        updateCodePane()
        syncMergeEditor()
        updateCommitActions()
        updateDetailBar()
        syncWelcomeVisibility()
        let showsStrip = model.snapshot != nil && SectionPanes(model.section).showsHistoryPane
        strip.isHidden = !showsStrip
        stripHeight.constant = showsStrip ? RepositoryLayout.stripHeight : 0
        if change == .selection || change == .diff {
            updateWorkingChangesBanner()
            syncHistoryDetailOverlay()
        }
    }

    private func syncWelcomeVisibility() {
        let hidden = model.snapshot != nil || model.isLoading
        welcome.isHidden = hidden
        if hidden {
            if welcome.superview != nil { welcome.removeFromSuperview() }
        } else if welcome.superview !== historyPane {
            Style.fill(welcome, in: historyPane)
        }
    }

    /// The operation bar for the model's operation and conflicts, with Resolve Simple when the scan found files for it.
    func applyOperationBar() {
        let operation = OperationBarState(
            operation: model.snapshot?.operation, currentBranch: model.snapshot?.branch,
            conflicts: model.conflictCount, simpleConflicts: simpleScan.simplePaths.count,
            isBusy: model.isMutating || model.isLoading)
        operationBar.apply(operation)
        operationHeight.constant = operation.isHidden ? 0 : OperationBarView.height
    }

    /// Retry loading history: shown while a page failed and more history remains.
    private func updateRetryFooter() {
        let more = model.displayedHistoryHasMore
        let loading = model.displayedHistoryIsLoading
        loadMore.isEnabled = more && !loading
        let pageFailed = more && !loading && model.historyPageFailed
        // The failed page may be read again automatically once the failure is gone (another history, a retry).
        if model.historyPageFailed { lastAutomaticPage = nil }
        loadMore.title = String(localized: "Retry loading history")
        loadMore.isHidden = !pageFailed
        historyFooterHeight.constant = pageFailed ? RepositoryLayout.retryFooterHeight : 0
    }

    /// Settings › Appearance › Code font (and Interface font): everything that typesets text itself re-renders in
    /// place.
    func codeFontChanged() {
        historyTable.reloadVisibleRows()
        codePane.diffView.table.reloadData()
        strip.reconfigure()
        rebuildCommitDetail()
        updateDetailBar()
        refreshPage()
        refreshOverview()
    }

    func agentsChanged() {
        guard isViewLoaded, view.window != nil else { return }
        indexAgents()
        historyTable.reloadSignals()
        rebuildSidebar()
        refreshStrip()
        refreshOverview()
    }

    /// Agent sessions keyed by the commit their checkout has checked out (status chips).
    func indexAgents() {
        guard let snapshot = model.snapshot else {
            agentsByCommit = [:]
            return
        }
        let sessions = WindowAgents.shared.sessions(
            repository: snapshot.root, worktreePaths: snapshot.worktrees.map(\.path))
        agentsByCommit = AgentCommitIndex.build(sessions, snapshot: snapshot) { WindowAgents.key($0) }
    }
}
