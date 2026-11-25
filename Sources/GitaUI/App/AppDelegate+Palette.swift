import AppKit
import GitaCore

private typealias Tab = RepositoryCommandResponder

/// The command palette: what it lists (every command of the menus, the selected repository's branches, commits,
/// pull requests, workflow runs and deployments, the workspaces, the repositories and the Settings panes) and what
/// choosing one does.
extension AppDelegate {
    private static let rememberedChoices = 30

    /// More words a command is found by: "go to workflows", "open terminal", "checkout".
    private static let paletteAliases: [Selector: [String]] = [
        #selector(navigate(_:)): ["go to", "open", "show", "page"],
        #selector(showDetailTab(_:)): ["go to", "show", "tab"],
        #selector(settings): ["preferences", "options"],
        #selector(checkForUpdates): ["upgrade", "version"],
        #selector(toggleTerminal): ["open terminal", "hide terminal", "shell", "console"],
        #selector(newTerminal): ["open terminal", "shell", "console"],
        #selector(openRepository): ["add repository", "folder"],
        #selector(newTab): ["welcome", "launchpad", "open project", "recent"],
        #selector(refresh): ["reload"],
        #selector(quit): ["exit"],
        #selector(Tab.openRemote): ["browser", "web", "website"],
        #selector(Tab.reveal): ["open folder", "show in finder"],
        #selector(Tab.switchBranch): ["checkout"],
        #selector(Tab.stash): ["save changes"],
        #selector(showSubmodulesAndLFS): [
            "submodule", "submodules", "lfs", "git lfs", "locks", "large files", "manage submodules",
            "manage git lfs",
        ],
    ]

    /// View › Command Palette… (⌘K by default).
    @objc func showCommandPalette() { showPalette(scope: nil) }

    /// The palette over the main window, showing `scope` alone (nil: everything). The branches' dates follow a
    /// moment later.
    func showPalette(scope: PaletteKind?) {
        guard !isLanguageRestarting, setupGuide == nil else { return }
        showWindow()
        guard let window = mainWindow, window.attachedSheet == nil else {
            environment.system.beep()
            return
        }
        palette?.close()
        let palette = PaletteController(scope: scope, recents: Preference.paletteRecents.strings(defaults))
        // Read once, while the main window still has the keyboard: the menus validate against it.
        let fixed = paletteCommands() + paletteRepositories() + paletteWorkspaces()
        let snapshot = model.snapshot
        let canSwitch = availability.isEnabled(.switchBranch)
        palette.update(fixed + repositoryItems(snapshot, dates: [:], canSwitch: canSwitch))
        palette.onChoose = { [weak self] item in self?.run(item) }
        palette.onNewBranch = { [weak self] name in self?.newBranchFromPalette(name) }
        palette.onUnavailable = { [weak self] in self?.environment.system.beep() }
        palette.show(over: window)
        self.palette = palette
        guard let snapshot, let service = model.service else { return }
        Task { [weak self, weak palette] in
            let dates = await service.branchDates()
            guard let self, let palette, !dates.isEmpty else { return }
            palette.update(fixed + self.repositoryItems(snapshot, dates: dates, canSwitch: canSwitch))
        }
    }

    // MARK: Items

    private func paletteCommands() -> [PaletteItem] {
        guard let menu = NSApp.mainMenu else { return [] }
        // The palette itself, and Open Recent, whose repositories the palette lists.
        let skipped: Set<Selector> = [#selector(showCommandPalette), #selector(openRecent)]
        let menus = PaletteItems.commands(in: menu, skipping: skipped, aliases: Self.paletteAliases) {
            [self] in validateMenuItem($0)
        }
        return menus + windowCommands() + toolbarCommands() + PaletteItems.settings
    }

    /// What only the window's buttons offer: Create PR…, Stage all and Commit staged.
    private func windowCommands() -> [PaletteItem] {
        var items = (repositoryController?.paletteActions() ?? []).map { action in
            PaletteItems.command(
                action.item, group: String(localized: "Repository"), keywords: action.keywords,
                isEnabled: action.item.isEnabled)
        }
        let hasRepo = model.snapshot != nil && model.service != nil
        let submodules = MenuAction(String(localized: "Manage Submodules"), symbol: "shippingbox") { [weak self] in
            self?.openSubmodulesAndLFS(initialTab: .submodules)
        }
        let lfs = MenuAction(String(localized: "Manage Git LFS"), symbol: "externaldrive.badge.checkmark") {
            [weak self] in
            self?.openSubmodulesAndLFS(initialTab: .lfs)
        }
        items.append(
            PaletteItems.command(
                submodules, group: String(localized: "Repository"),
                keywords: ["submodule", "submodules", "init", "sync", "update"], isEnabled: hasRepo))
        items.append(
            PaletteItems.command(
                lfs, group: String(localized: "Repository"),
                keywords: ["lfs", "git lfs", "locks", "large files", "unlock"], isEnabled: hasRepo))
        return items
    }

    /// What only the toolbar offers: the sidebar, and Open in ▾ (Finder, the terminal, the editor, Vercel).
    private func toolbarCommands() -> [PaletteItem] {
        let view = NSMenu()
        view.addItem(
            MenuAction(String(localized: "Sidebar"), symbol: "sidebar.left") { [weak self] in
                self?.toggleRepositorySidebar()
            })
        let sidebar = PaletteItems.commands(in: view, group: String(localized: "View")) { _ in true }
        guard let snapshot = model.snapshot else { return sidebar }
        // The remote's page is already Repository › Open on GitHub.
        let page = RemotePage.repository(snapshot)
        let remote = page.map(RemoteWebPage.hostName(of:))
        let places = ToolbarMenus.openIn(root: snapshot.root, remote: page, signals: model.allSignals)
        let openIn = PaletteItems.commands(in: places) { _ in true }.filter { $0.title != remote }.map { place in
            var item = place
            item.title = String(localized: "Open in \(place.title)")
            return item
        }
        return sidebar + openIn
    }

    private func paletteRepositories() -> [PaletteItem] {
        PaletteItems.repositories(
            open: tabsController?.tabs.compactMap(\.repositoryRoot) ?? [], selected: tabsController?.selectedRepository,
            recent: Preference.recentRepositories.strings(defaults), canOpen: canChangeRepository)
    }

    private func paletteWorkspaces() -> [PaletteItem] {
        let windowed = Set(places.filter { $0.windows.window != nil }.map(\.workspace.id))
        return PaletteItems.workspaces(
            workspaces.workspaces, selected: place.workspace.id, windowed: windowed, canSwitch: canChangeWorkspace)
    }

    private func repositoryItems(
        _ snapshot: RepositorySnapshot?, dates: [String: Date], canSwitch: Bool
    )
        -> [PaletteItem]
    {
        guard let snapshot else { return [] }
        let defaults = defaults
        return PaletteItems.branches(BranchPaletteEntries.make(snapshot, dates: dates), canSwitch: canSwitch)
            + PaletteItems.provider(model.allSignals) { ProviderPageState.isShown($0, defaults) }
            + PaletteItems.commits(snapshot.commits)
    }

    // MARK: Choosing

    /// Runs a chosen item and remembers it: the next showing lists it first among its kind.
    func run(_ item: PaletteItem) {
        let recents = [item.id] + Preference.paletteRecents.strings(defaults).filter { $0 != item.id }
        Preference.paletteRecents.set(Array(recents.prefix(Self.rememberedChoices)), defaults)
        switch item.action {
        case .menu(let menuItem): run(menuItem)
        case .branch(let entry): commands.choose(entry)
        case .provider(let signal): repositoryController?.openProviderContext(signal)
        case .repository(let url): openRepositoryTab(url)
        case .workspace(let id): openWorkspace(id)
        case .commit(let id): repositoryController?.showCommit(id: id)
        case .settings(let pane): SettingsWindowController.shared.show(pane)
        }
    }

    /// A menu item's action, sent as its menu would: validated now, then to its target or along the chain.
    private func run(_ menuItem: NSMenuItem) {
        guard let action = menuItem.action, validateMenuItem(menuItem) else {
            environment.system.beep()
            return
        }
        NSApp.sendAction(action, to: menuItem.target, from: menuItem)
    }

    /// ⌘N in the palette: New Branch, named after what was typed if that can be a branch's name.
    private func newBranchFromPalette(_ typed: String) {
        guard availability.isEnabled(.newBranch) else {
            environment.system.beep()
            return
        }
        commands.newBranchNamed(typed.contains(" ") ? "" : typed)
    }
}
