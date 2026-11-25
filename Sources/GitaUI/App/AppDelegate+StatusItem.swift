import AppKit
import GitaCore

/// The menu bar item's host: what its panel lists and what its rows do.
extension AppDelegate: StatusItemHost {
    var panelActions: MenuPanelActions {
        MenuPanelActions(
            openApp: { [weak self] in self?.showWindow() },
            refresh: { [weak self] in
                guard let self else { return }
                self.refresh()
                WorkspaceMonitor.shared.refresh()
                self.statusItem?.refresh()
            },
            settings: { [weak self] in self?.settings() },
            quit: { [weak self] in self?.quit() },
            openRepository: { [weak self] in self?.openRepository() },
            showRepository: { [weak self] url in self?.showRepositoryTab(url) == true },
            showTab: { [weak self] url, workspace in self?.showTab(url, inWorkspace: workspace) },
            push: { [weak self] url in self?.statusItem?.push(url) },
            reveal: { [weak self] session in self?.reveal(session) },
            openWorkspace: { [weak self] id in self?.openWorkspace(id) },
            newWorkspace: { [weak self] in self?.newWorkspace() },
            installUpdate: { [weak self] in self?.installAvailableUpdate() })
    }

    /// Every workspace as the panel lists it: in the front window, in another window, resting (a window's own
    /// while that window is closed) or closed, with its tabs: the open ones, else the ones it saved.
    var panelWorkspaces: [MenuPanelState.Workspace] {
        workspaces.workspaces.map { workspace in
            let shown = places.first { $0.workspace.id == workspace.id }
            var seen = Set<String>()
            return MenuPanelState.Workspace(
                id: workspace.id, title: workspace.title, presence: presence(of: shown),
                repositories: (shown?.repositories ?? savedRepositories(of: workspace))
                    .map(MenuPanelState.Repository.id).filter { seen.insert($0).inserted })
        }
    }

    private func presence(of shown: WorkspaceWindow?) -> MenuPanelState.Workspace.Presence {
        guard let shown else { return .closed }
        guard shown.windows.window != nil else { return .resting }
        return shown === place ? .front : .window
    }

    /// The tabs a workspace without a window saved.
    func savedRepositories(of workspace: Workspace) -> [URL] {
        RepositoryTabSession.restore(from: defaults, key: workspace.sessionKey)?.repositories ?? []
    }

    /// A pill: the repository's tab in the window of the workspace the pill is in. A repository can be a tab of
    /// several workspaces; without that window (it closed since) it shows wherever it is open.
    private func showTab(_ url: URL, inWorkspace id: String) {
        guard gate.canOpenWindowContent, let shown = places.first(where: { $0.workspace.id == id }) else {
            openRepositoryTab(url)
            return
        }
        focus(shown)
        showWindow()
        tabsController?.open(url)
    }

    /// An agent row: its terminal comes forward, else its checkout opens in a tab; either way it counts as seen.
    private func reveal(_ session: AgentSession) {
        if !AgentMonitor.shared.reveal(session) {
            openRepositoryTab(session.checkoutRoot ?? session.repositoryRoot ?? session.workingDirectory)
        }
        AgentMonitor.shared.markSeen(repository: session.repositoryRoot ?? session.workingDirectory)
    }

    func selectPanelRepository(_ url: URL) {
        guard canChangeRepository else {
            environment.system.beep()
            return
        }
        cancelAttentionNavigation()
        focusWindow(showing: url)
        if let tabsController {
            _ = tabsController.open(url)
        } else {
            let canonical = RepositoryTabSession.canonical(url)
            var session = repositorySession ?? RepositoryTabSession()
            session.focus(canonical)
            repositorySession = session
            session.save(to: defaults, key: place.workspace.sessionKey)
            restingRepository = canonical
            if model.snapshot?.root != canonical { restingModel.open(canonical) }
        }
        statusItem?.show(model)
    }

    func panelVisibilityChanged() {
        updateMonitorRepositories()
        updateMonitorVisibility()
    }

    /// View › Show Menu Panel.
    @objc func togglePanel() { statusItem?.togglePanel() }
}
