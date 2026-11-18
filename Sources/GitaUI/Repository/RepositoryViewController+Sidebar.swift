import AppKit
import GitaCore

/// The sidebar: what it lists for this repository and every other one, and what choosing a row does.
extension RepositoryViewController {
    func wireSidebar() {
        sidebarView.onOpenCheckout = { [weak self] url in self?.openRepository(url) }
        sidebarView.onNavigate = { [weak self] id in self?.navigate(id) }
        sidebarView.onReference = { [weak self] reference in
            self?.sidebarSelection = .reference(fullName: reference.fullName)
            self?.jumpTo(reference)
        }
        sidebarView.onStash = { [weak self] stash in
            self?.sidebarSelection = nil
            self?.model.selectStash(stash)
        }
        sidebarView.referenceMenu = { [weak self] reference in self?.referenceMenu(reference) }
        sidebarView.remoteMenu = { _ in Self.remoteMenu() }
        sidebarView.onFilter = { [weak self] reference, kind in self?.model.toggleBranchFilter(kind, reference) }
        sidebarView.checkoutMenu = { [weak self] path, isMain in self?.checkoutMenu(path: path, isMain: isMain) }
        sidebarView.repositoryMenu = { [weak self] repository in self?.repositoryMenu(repository) }
    }

    /// Manage Remotes… goes up the responder chain to the selected tab's commands.
    private static func remoteMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: String(localized: "Manage Remotes…"), action: #selector(RepositoryCommandResponder.manageRemotes),
            keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    private func navigate(_ id: SidebarSelection) {
        sidebarSelection = nil
        if let section = id.section {
            model.section = section
            return
        }
        if model.section != .history { model.section = .history }
        if model.focusedReference != nil || model.isSearchingHistory || model.selectedStash != nil {
            model.showAllHistory()
        }
        rebuildSidebar()
    }

    /// A repository or checkout row: this tab's own repository shows History; any other opens in a tab.
    func openRepository(_ url: URL) {
        if let root = model.snapshot?.root, WindowAgents.key(root) == WindowAgents.key(url) {
            if !SectionPanes(model.section).showsHistoryPane { model.section = .history }
            return
        }
        commands?.openRepositoryTab(url)
    }

    var sidebarSelectionID: SidebarSelection {
        if let page = SidebarSelection(page: model.section) { return page }
        if let stash = model.selectedStash { return .stash(ref: stash.ref) }
        if let reference = model.focusedReference { return .reference(fullName: reference.fullName) }
        return sidebarSelection ?? .history
    }

    func rebuildSidebar() {
        var input = RepositorySidebarView.Input()
        input.currentRoot = model.snapshot?.root
        input.currentName = model.snapshot?.root.lastPathComponent ?? ""
        input.selection = sidebarSelectionID
        if let snapshot = model.snapshot { fillSidebar(&input, snapshot: snapshot) }
        input.repositories = sidebarRepositories()
        sidebarView.update(input)
    }

    private func fillSidebar(_ input: inout RepositorySidebarView.Input, snapshot: RepositorySnapshot) {
        input.references = snapshot.references
        input.stashes = snapshot.stashes
        input.remotes = RemoteBranchName.remotes(in: snapshot.references)
        input.remoteURLs = snapshot.remoteURLs
        input.githubRemotes = snapshot.githubRemotes
        input.changes = snapshot.changes.count
        let signals = ProviderSignalQuery(signals: model.allSignals)
        input.pullRequests = signals.openPullRequests
        input.workflows = signals.activeWorkflows
        input.deployments = signals.deployments
        input.showsGitHub = Integration.github.isEnabled()
        input.showsVercel = Integration.vercel.isEnabled()
        input.branchComments = model.vercelContext?.comments?.byBranch ?? [:]
        input.productionBranch = model.productionBranch
        input.filters = model.branchFilters
        // Linked worktrees (the first entry is the main checkout, or the bare repository); a detached one has no
        // branch.
        let branches = Set(snapshot.references.filter { $0.kind == .branch }.map(\.name))
        for tree in snapshot.worktrees.dropFirst() {
            if let branch = tree.branch, branches.contains(branch) { input.worktreeBranches[branch] = tree.path }
        }
        for tree in snapshot.worktrees {
            guard let branch = tree.branch,
                let session = WindowAgents.shared.sessions(checkout: URL(fileURLWithPath: tree.path)).first
            else { continue }
            input.branchAgents[branch.replacingOccurrences(of: "refs/heads/", with: "")] = AgentMarkState(session)
        }
    }

    private func sidebarRepositories() -> [RepositorySidebarView.Repository] {
        let monitor = WorkspaceMonitor.shared
        return SidebarRepositoryList(
            snapshot: model.snapshot, statuses: workspaceStatuses, status: { monitor.status(for: $0) },
            openRepositories: tabs?.openRepositories ?? [], recent: model.recent, loading: tabs?.loadingCheckouts ?? [],
            key: { WindowAgents.key($0) }, sessionsAt: { WindowAgents.shared.sessions(checkout: $0) },
            sessionsIn: { WindowAgents.shared.sessions(repository: $0) }
        ).repositories()
    }

    /// The monitor's repositories that belong to this window's workspace: its open tabs and its own recently opened
    /// list. The monitor follows every workspace; the sidebar and the Agents pane list only their own.
    var workspaceStatuses: [RepositoryStatus] {
        guard let tabs else { return WorkspaceMonitor.shared.statuses }
        let roots = tabs.openRepositories + model.recent.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let own = Set(roots.compactMap { WindowAgents.key($0) })
        return WorkspaceMonitor.shared.statuses.filter { WindowAgents.key($0.root).map(own.contains) == true }
    }

    /// The open tabs' loading state changed (a checkout started or finished opening): redraw the spinners.
    func checkoutLoadingChanged() {
        guard isViewLoaded, view.window != nil else { return }
        rebuildSidebar()
    }
}
