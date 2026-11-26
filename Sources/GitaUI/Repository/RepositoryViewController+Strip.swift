import AppKit
import GitaCore

/// The worktree strip over the history, the provider pages, and the Worktrees & Agents pane.
extension RepositoryViewController {
    func wireStrip() {
        stripHeight.isActive = false
        strip.heightConstraint.isActive = true
        strip.onAgent = { [weak self] session in
            if let session { WindowAgents.shared.reveal(session) } else { self?.showAgentsPane() }
        }
        strip.onCreatePullRequest = { [weak self] in self?.createPullRequest() }
        strip.onChecks = { [weak self] in self?.showHeadChecks() }
        strip.onFetch = { [weak self] in
            guard self?.model.snapshot != nil else { return }
            NSApp.sendAction(#selector(RepositoryCommandResponder.fetchNow), to: nil, from: nil)
        }
    }

    /// The strip's checks: the head commit's Commit tab in All Commits.
    private func showHeadChecks() {
        if let head = model.snapshot?.head { showCommit(id: head) }
    }

    /// All Commits with the commit selected, out of any branch focus or search that could hide it.
    func showCommit(id: String) {
        if model.section != .history { model.section = .history }
        if model.focusedReference != nil || model.isSearchingHistory { model.showAllHistory() }
        selectCommit(id: id)
        if !model.showsHistoryDetails { model.toggleHistoryDetails() }
        selectDetailTab(.commit)
    }

    private var signalQuery: ProviderSignalQuery { ProviderSignalQuery(signals: model.allSignals) }

    /// The checks of the commit `head`: its workflow runs and deployments, one per workflow or environment.
    func checks(for head: String?) -> [ProviderItem] {
        guard let head,
            let commit = model.snapshot?.commits.first(where: { $0.id == head })
                ?? historyTable.commits.first(where: { $0.id == head })
        else { return [] }
        return ProviderSignalQuery.checks(model.signals(for: commit))
    }

    func refreshStrip() {
        guard let snapshot = model.snapshot else { return }
        let presenter = WorktreeStripPresenter(
            snapshot: snapshot, sessions: WindowAgents.shared.sessions(checkout: snapshot.root), signals: signalQuery,
            checks: checks(for: snapshot.head), vercel: model.vercelContext,
            productionBehind: model.productionBehind, productionBranch: model.productionBranch,
            remoteDelta: model.remoteDelta, remoteCheckStatusSummary: model.remoteCheckStatusSummary)
        var input = presenter.input
        input.shown = WorktreeStripView.Cell.shown()
        strip.update(input)
    }

    /// Create PR…: `gh pr create --web` in this checkout; falls back to GitHub's compare page. Either way the page
    /// opens in the browser with the browser's own GitHub account, which Gita cannot choose, so `gh` runs as its
    /// active account here rather than the one stored for the repository.
    func createPullRequest() {
        guard let snapshot = model.snapshot, let branch = WorktreeStripPresenter.branch(of: snapshot) else { return }
        let root = snapshot.root
        let github = snapshot.github?.webURL
        Task { @MainActor in
            let result = try? await CommandRunner().run(
                executable: "gh", arguments: ["pr", "create", "--web", "--head", branch], directory: root, timeout: 20)
            if result?.exitCode != 0, let github,
                let compare = WorktreeStripPresenter.compareURL(github: github, branch: branch)
            {
                Deck.open(compare)
            }
        }
    }

    // MARK: Pages

    func refreshPage() {
        guard ProviderPageState.isProviderPage(model.section) else { return }
        // Its integration was switched off while the page was open.
        guard ProviderPageState.isShown(model.section) else {
            model.section = .history
            return
        }
        if model.section != .deployments { model.readGitHubAccounts() }
        providerPage.update(
            ProviderPageState(
                section: model.section, signals: model.allSignals, reports: model.reports,
                accounts: model.githubAccountPicker, viewerLogin: model.providers.viewerLogin),
            vercel: model.vercelContext)
        syncPullRequestWorkspaceMode()
    }

    /// Notification / menu-panel routing: show the item expanded in place on its page.
    func openProviderContext(_ item: ProviderItem) {
        guard let window = view.window, window.attachedSheet == nil, !hasReviewSheet, !model.isMutating else { return }
        if item.kind == .agent {
            showAgentsPane()
            return
        }
        if item.provider == .github {
            model.section = item.kind == .workflowRun ? .workflows : .pullRequests
        } else if item.provider == .vercel {
            model.section = .deployments
        }
        if !providerPage.reveal(item), let url = Deck.safeWebURL(item.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Worktrees & Agents

    func wireOverview() {
        agentsPane.onReveal = { WindowAgents.shared.reveal($0) }
        agentsPane.onOpenCheckout = { [weak self] url in self?.openRepository(url) }
        agentsPane.onShowInHistory = { [weak self] row in self?.showInHistory(row) }
        agentsPane.onInspectStorage = { [weak self] url in self?.commands?.inspectStorage(at: url) }
        agentsPane.onNewWorktree = { [weak self] in
            guard self?.model.canStartOperation == true else { return }
            self?.commands?.newWorktree()
        }
    }

    private func showInHistory(_ row: AgentsPaneView.Row) {
        if WindowAgents.key(URL(fileURLWithPath: row.checkoutPath)) != WindowAgents.key(model.snapshot?.root) {
            openRepository(URL(fileURLWithPath: row.checkoutPath, isDirectory: true))
            return
        }
        model.section = .history
        if let head = model.snapshot?.head { selectCommit(id: head) }
    }

    /// Rows for the Agents pane; nothing to do while it is closed.
    func refreshOverview() {
        guard isViewLoaded, !agentsPane.isHidden else { return }
        let monitor = WorkspaceMonitor.shared
        let builder = AgentsOverviewBuilder(
            snapshot: model.snapshot, sessions: WindowAgents.shared.sessions, statuses: workspaceStatuses,
            status: { monitor.status(for: $0) }, signals: signalQuery,
            checks: { [weak self] in self?.checks(for: $0) ?? [] },
            key: { WindowAgents.key($0) })
        agentsPane.canCreateWorktree = model.canStartOperation
        agentsPane.update(rows: builder.rows())
    }
}
