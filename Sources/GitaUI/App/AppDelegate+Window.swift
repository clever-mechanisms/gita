import AppKit
import GitaCore

/// The main windows: each built around its workspace's repository tabs on first show, released on close (the
/// selected repository and the tab session stay for the next show), and the monitors' sampling while something
/// shows them.
extension AppDelegate {
    /// A main window's place, closed: `autosaveName` nil for the first one, which keeps the frame saved before
    /// workspaces existed.
    static func makePlace(
        _ workspace: Workspace, environment: AppEnvironment, autosaveName: String?
    ) -> WorkspaceWindow {
        let model = environment.system.makeModel(environment.defaults)
        model.recentKey = workspace.recentKey
        let windows = MainWindowController(
            savesFrame: !environment.isDevelopment, activation: environment.system.activation,
            autosaveName: autosaveName ?? MainWindowController.autosaveName)
        return WorkspaceWindow(workspace: workspace, windows: windows, restingModel: model)
    }

    /// A window that is closing, or was clicked, is the one the shell acts on from then.
    func configureWindowCallbacks(_ place: WorkspaceWindow) {
        let windows = place.windows
        windows.shouldClose = { [weak self, weak place] in
            guard let self, let place else { return true }
            self.focus(place)
            guard self.place === place, self.mainWindowShouldClose() else { return false }
            // Open terminals: the window closes once the user agrees to end them.
            return self.confirmingTerminals(
                String(localized: "Close the window?"), button: String(localized: "Close Window")
            ) { [weak self, weak place] in
                guard let self, let place else { return }
                self.focus(place)
                if self.place === place, self.mainWindowShouldClose() { self.mainWindow?.close() }
            }
        }
        windows.willClose = { [weak self, weak place] _ in
            guard let self, let place else { return }
            self.focus(place, force: true)
            self.mainWindowWillClose()
        }
        windows.didClose = { [weak self, weak place] in
            guard let self, let place else { return }
            self.mainWindowDidClose(place)
        }
        windows.occlusionChanged = { [weak self] in
            self?.updateMonitorVisibility()
            self?.loginOffer.update()
        }
        windows.didBecomeMain = { [weak self, weak place] in
            guard let self, let place else { return }
            self.focus(place)
        }
    }

    /// The built-in terminal opens in the main window's panel, the window shown first. Before launch, while the
    /// setup guide shows or while restarting for a language there is no panel to take it: it is refused (with a
    /// beep), and a review script that will never run is removed.
    func openTerminal(_ directory: URL, launch: TerminalSession.Launch) {
        guard gate.canOpenWindowContent else {
            environment.system.beep()
            if case .script(let script) = launch { ReviewScripts.discard(script) }
            return
        }
        showWindow()
        tabsController?.terminalPanel.open(directory, launch: launch)
    }

    /// View ▸ Show Terminal (⌃`): the main window's terminal panel shows or hides.
    @objc func toggleTerminal() {
        showWindow()
        tabsController?.toggleTerminalPanel()
    }

    /// View ▸ New Terminal (⌃⇧`): a shell in the selected repository's folder, in the panel.
    @objc func newTerminal() {
        showWindow()
        tabsController?.terminalPanel.openShell()
    }

    @objc func showWindow() {
        guard didFinishLaunching else {
            launch.requestWindow()
            return
        }
        statusItem?.closePanel()
        if mainWindow == nil { makeMainWindow() }
        windows.bringToFront()
        tabsController?.setWindowVisible(true)
        updateMonitorVisibility()
        model.log(String(localized: "Window opened"))
        if initialSetupPending, model.snapshot == nil, model.service == nil, mainWindow?.attachedSheet == nil,
            attention.pending == nil
        {
            initialSetupPending = false
            presentSetupGuide()
        }
        loginOffer.update()
    }

    private func makeMainWindow() {
        let tabs = makeTabs()
        // A further workspace's window opens beside the others, not exactly over them.
        let neighbor = places.lazy.filter { $0 !== self.place }.compactMap(\.windows.window).first
        _ = windows.make(tabs, cascadingFrom: neighbor)
        tabs.refreshTabs() // the window's title, now that the tabs are in it
        observeActiveModel(tabs.selectedModel)
        updateMonitorRepositories()
    }

    /// The window's tabs: the workspace's saved ones, the resting model in the tab of its repository.
    func makeTabs() -> RepositoryTabsController {
        let place = place
        let defaults = defaults
        let tabs = RepositoryTabsController(
            initialModel: restingModel, initialURL: restingRepository, session: repositorySession,
            workspace: place.workspace, environment: environment.system.tabs)
        tabs.onSelectionChange = { [weak self, weak place] model in
            // A tab that finished opening in a window behind is not the shell's active model.
            if let self, self.place === place { self.observeActiveModel(model) }
        }
        tabs.onOpenRepository = { [weak self] in self?.openRepository() }
        tabs.onLastTabClosed = { [weak place] in place?.windows.window?.performClose(nil) }
        tabs.onSessionChange = { [weak self, weak place] session in
            guard let self, let place else { return }
            place.session = session
            session.save(to: defaults, key: place.workspace.sessionKey)
            self.updateMonitorRepositories()
        }
        tabs.workspaceMenu = { [weak self] in self?.workspaceMenu.menu() }
        place.session = tabs.session
        tabs.session.save(to: defaults, key: place.workspace.sessionKey)
        return tabs
    }

    /// True when the front window has no open terminal. Else asks, on the window, whether to end them (closing the
    /// window, or giving it to another workspace, hangs up the programs running in them), and runs `action` on the
    /// next turn of the run loop when the user agrees.
    func confirmingTerminals(_ title: String, button: String, _ action: @escaping @MainActor () -> Void) -> Bool {
        let count = tabsController?.terminalPanel.openCount ?? 0
        guard count > 0, let window = mainWindow else { return true }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = Self.openTerminalsWarning(count)
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        environment.system.alerts.confirm(alert, on: window) { DispatchQueue.main.async { action() } }
        return false
    }

    static func openTerminalsWarning(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "A terminal is open in this window. Closing it ends the program running in it.")
        }
        return String(
            localized:
                "\(count) terminals are open in this window. Closing them ends the programs running in them.")
    }

    /// Whether the window may close as far as its sheets, Git actions and commit drafts go.
    func mainWindowShouldClose() -> Bool {
        if isLanguageRestarting { return false }
        if let session = setupGuide {
            finishSetupGuide(session.id, choices: nil)
            return false
        }
        if repositoryController?.closeReviewSheet() == true { return false }
        if let sheet = mainWindow?.attachedSheet {
            sheet.performClose(nil)
            return false
        }
        if tabsController?.isMutating == true {
            environment.system.beep()
            return false
        }
        return flushCommitDrafts()
    }

    private func mainWindowWillClose() {
        loginOffer.hide()
        closeTabs()
    }

    /// The window's tabs go (the window closes, or another workspace takes their place): the selected tab's model
    /// stays as the resting one, the session is saved, and the terminals end, as closing a terminal window ends them.
    func closeTabs() {
        cancelAttentionNavigation()
        restingModel = model
        restingRepository = tabsController?.selectedRepository ?? restingModel.snapshot?.root
        repositorySession = tabsController?.session ?? repositorySession
        place.saveSession(to: defaults)
        tabsController?.terminalPanel.closeAll()
        tabsController?.detach(preserving: restingModel)
        restingModel.isWindowVisible = false
    }

    /// A workspace's own window is gone with its place; the first window's place stays for the next show.
    private func mainWindowDidClose(_ closed: WorkspaceWindow) {
        closed.restingModel.log(String(localized: "Window closed"))
        if places.count > 1 { drop(closed) }
        updateMonitorVisibility()
    }

    /// Removes a closed window's place; the shell moves to the window now in front.
    private func drop(_ closed: WorkspaceWindow) {
        places.removeAll { $0 === closed }
        closed.restingModel.stop()
        let front = places.first { $0.windows.window?.isMainWindow == true } ?? places.last
        if place === closed, let front {
            place = front
            placeChanged()
        } else {
            updateMonitorRepositories()
        }
    }

    /// `place` is the main window the shell acts on. Not while the setup guide or a language restart holds the
    /// current one (`force` when the window is closing regardless).
    func focus(_ place: WorkspaceWindow, force: Bool = false) {
        guard place !== self.place, places.contains(where: { $0 === place }) else { return }
        guard force || (setupGuide == nil && !isLanguageRestarting) else { return }
        loginOffer.hide()
        self.place = place
        placeChanged()
    }

    /// Another window (or another workspace in the window) is the active one: it is the workspace the next launch
    /// opens, and its selected tab is the active model.
    func placeChanged() {
        workspaces.activate(place.workspace.id)
        workspaces.save(to: defaults)
        observeActiveModel(model)
        updateMonitorRepositories()
        loginOffer.update()
    }

    func saveSessions() { places.forEach { $0.saveSession(to: defaults) } }

    // MARK: Every window

    /// A Git action runs in a tab of any window.
    var isAnyMutating: Bool { places.contains { place in place.models.contains(where: \.isMutating) } }

    /// The repository view with a review sheet open, in the front window first.
    var reviewingController: RepositoryViewController? {
        ([place] + places.filter { $0 !== place }).lazy
            .compactMap { $0.tabs.flatMap { $0.isEmpty ? nil : $0.selectedController } }
            .first(where: \.hasReviewSheet)
    }

    func flushAllCommitDrafts() -> Bool {
        places.allSatisfy { $0.tabs?.flushCommitDrafts() ?? $0.restingModel.flushCommitDraft() }
    }

    // MARK: Panes (toolbar, View menu, deep links)

    /// Toolbar Workspaces: the same menu as File ▸ Workspace and the tab bar's workspace button.
    func workspaceSwitcherMenu() -> NSMenu? { workspaceMenu.menu() }

    /// Toolbar Agents button and View ▸ Worktrees & Agents: the right-hand pane opens or closes.
    func toggleAgentsPane() {
        showWindow()
        repositoryController?.toggleAgentsPane()
    }

    /// Opens the pane (Repository menu, deep links) without closing it when already open.
    func showAgentsPane() {
        showWindow()
        repositoryController?.showAgentsPane()
    }

    func toggleRepositorySidebar() { repositoryController?.toggleSidebar() }

    // MARK: Monitors

    /// Agents and repository statuses sample fast only while a window or the panel shows them.
    func updateMonitorVisibility() {
        let visible = places.contains { $0.windows.isShowing } || statusItem?.isPanelShown == true
        WorkspaceMonitor.shared.setVisible(visible)
        AgentMonitor.shared.setVisible(visible)
    }

    func updateMonitorRepositories() { WorkspaceMonitor.shared.setRepositories(panelRepositoryURLs) }

    /// The front window's tabs first, then the other windows', then the tabs saved by the workspaces without a
    /// window, then every workspace's recent repositories (the front one's first), de-duplicated. The menu bar panel
    /// lists the tabs; the recent ones are followed for the sidebars.
    var panelRepositoryURLs: [URL] {
        let others = places.filter { $0 !== place }
        let open = place.repositories + (model.snapshot.map { [$0.root] } ?? []) + others.flatMap(\.repositories)
        let closed = workspaces.workspaces.filter { workspace in
            !places.contains { $0.workspace.id == workspace.id }
        }.flatMap(savedRepositories)
        let lists = [place.workspace] + workspaces.workspaces.filter { $0.id != place.workspace.id }
        let recent = lists.flatMap { $0.recent(in: defaults) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return RepositoryTabSession(repositories: open + closed + recent).repositories
    }
}
