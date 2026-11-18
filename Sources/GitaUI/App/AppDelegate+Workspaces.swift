import AppKit

/// Workspaces: each is a set of repositories with its own tabs and recently opened list. Choosing one shows it in
/// the front window, in place of the workspace there, or in a window of its own (Settings ▸ General ▸ Workspaces).
/// A workspace already in a window comes forward instead. New, Rename and Delete act from the front window.
extension AppDelegate {
    /// Settings ▸ General ▸ Workspaces: a workspace opens in a window of its own.
    var opensWorkspacesInWindows: Bool { Preference.workspaceWindows.bool(defaults) }

    /// Whether the front window can give up its tabs for another workspace's, and a workspace be added, renamed or
    /// deleted: launched, no setup guide or language restart, no sheet open and no Git action running in its tabs.
    var canChangeWorkspace: Bool {
        gate.canOpenWindowContent && mainWindow?.attachedSheet == nil && canChangeRepository
    }

    /// File ▸ Workspace and the tab bar's workspace button.
    func workspaceMenuItems() -> [NSMenuItem] {
        let windowed = places.filter { $0.windows.window != nil }.map(\.workspace.id)
        let content = WorkspaceMenu.Content(
            list: workspaces, shown: place.workspace.id, windowed: Set(windowed), canChange: canChangeWorkspace)
        return WorkspaceMenu.items(
            content,
            actions: WorkspaceMenu.Actions(
                open: { [weak self] in self?.openWorkspace($0) }, new: { [weak self] in self?.newWorkspace() },
                rename: { [weak self] in self?.renameWorkspace() }, delete: { [weak self] in self?.deleteWorkspace() }))
    }

    /// Shows a workspace: its window when it is in one; else a window of its own, when Settings asks for that and a
    /// window is open; else the front window, in place of the workspace there.
    func openWorkspace(_ id: String) {
        guard didFinishLaunching, let workspace = workspaces[id] else { return }
        if let shown = places.first(where: { $0.workspace.id == id }) {
            focus(shown)
            if place === shown { showWindow() } else { environment.system.beep() }
            return
        }
        guard canChangeWorkspace else {
            environment.system.beep()
            return
        }
        if opensWorkspacesInWindows, mainWindow != nil {
            addPlace(for: workspace)
            showWindow()
            return
        }
        // The workspace in the window gives way, and its terminals end: asked first when any is open.
        let agreed = confirmingTerminals(
            String(localized: "Switch to “\(workspace.title)”?"), button: String(localized: "Switch Workspace")
        ) { [weak self] in self?.takeWindow(for: id) }
        if agreed { takeWindow(for: id) }
    }

    /// The front window shows the workspace `id` in place of its own, if it still can.
    private func takeWindow(for id: String) {
        guard let workspace = workspaces[id], !places.contains(where: { $0.workspace.id == id }),
            canChangeWorkspace, flushCommitDrafts()
        else { return }
        replaceWorkspace(with: workspace)
        showWindow()
    }

    /// A repository asked for from outside the windows (a notification, a link, the menu bar panel) shows where it
    /// is open: the shell moves to another workspace's window that has it in a tab.
    func focusWindow(showing repository: URL) {
        let holder = places.first { other in
            other !== place
                && other.tabs?.openRepositories.contains { AttentionRequest.sameLocation($0, repository) } == true
        }
        if let holder { focus(holder) }
    }

    /// A window of its own for `workspace`, in front.
    private func addPlace(for workspace: Workspace) {
        let added = Self.makePlace(
            workspace, environment: environment, autosaveName: "\(MainWindowController.autosaveName).\(workspace.id)")
        configureWindowCallbacks(added)
        added.restoreSession(from: defaults)
        startResting(added)
        places.append(added)
        focus(added)
    }

    /// The front window shows `workspace` instead of its own: its tabs are saved and closed (with their terminals),
    /// and the other's take their place.
    private func replaceWorkspace(with workspace: Workspace) {
        let hadWindow = mainWindow != nil
        if hadWindow {
            loginOffer.hide()
            closeTabs()
        } else {
            place.saveSession(to: defaults)
        }
        let left = restingModel
        place.workspace = workspace
        restingModel = environment.system.makeModel(defaults)
        restingModel.recentKey = workspace.recentKey
        left.stop()
        place.restoreSession(from: defaults)
        startResting(place)
        if hadWindow {
            let tabs = makeTabs()
            windows.replaceTabs(tabs)
            tabs.refreshTabs() // the window's title
            tabs.setWindowVisible(windows.isShowing)
        }
        placeChanged()
    }

    /// A place's resting model reads the repository its workspace last showed, as a launch does.
    private func startResting(_ place: WorkspaceWindow) {
        place.restingModel.start(openInitialRepository: false)
        if let repository = place.restingRepository { place.restingModel.open(repository) }
    }

    // MARK: New, Rename, Delete

    func newWorkspace() {
        guard canChangeWorkspace else {
            environment.system.beep()
            return
        }
        prompt(
            String(localized: "New workspace"), labels: [String(localized: "Name")],
            defaults: [workspaces.suggestedName]
        ) { [weak self] values in
            // The sheet is still closing: the new workspace opens on the next turn of the run loop.
            DispatchQueue.main.async { self?.addWorkspace(named: values[0]) }
        }
    }

    private func addWorkspace(named name: String) {
        guard let workspace = workspaces.add(named: name) else {
            environment.system.beep()
            return
        }
        workspaces.save(to: defaults)
        openWorkspace(workspace.id)
    }

    /// Renames the front window's workspace.
    func renameWorkspace() {
        guard canChangeWorkspace else {
            environment.system.beep()
            return
        }
        let id = place.workspace.id
        prompt(
            String(localized: "Rename workspace"), labels: [String(localized: "Name")],
            defaults: [place.workspace.title], button: String(localized: "Rename")
        ) { [weak self] values in
            guard let self, let renamed = self.workspaces.rename(id, to: values[0]) else {
                self?.environment.system.beep()
                return
            }
            self.workspaces.save(to: self.defaults)
            for place in self.places where place.workspace.id == id {
                place.workspace = renamed
                place.tabs?.workspace = renamed
            }
        }
    }

    /// Deletes the front window's workspace, after asking: its tabs and recent list are forgotten, its repositories
    /// are not touched. The last workspace stays.
    func deleteWorkspace() {
        guard canChangeWorkspace, workspaces.canRemove else {
            environment.system.beep()
            return
        }
        showWindow()
        let workspace = place.workspace
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete the workspace “\(workspace.title)”?")
        let terminals = tabsController?.terminalPanel.openCount ?? 0
        let forgotten = String(
            localized: "Its tabs and its list of recent repositories are forgotten. The repositories stay on disk.")
        // Deleting it closes its tabs, and with them its terminals: said here, not asked again afterwards.
        alert.informativeText = terminals > 0 ? forgotten + "\n\n" + Self.openTerminalsWarning(terminals) : forgotten
        alert.addButton(withTitle: String(localized: "Delete Workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        environment.system.alerts.confirm(alert, on: mainWindow) { [weak self] in
            DispatchQueue.main.async { self?.removeWorkspace(workspace.id) }
        }
    }

    private func removeWorkspace(_ id: String) {
        guard let workspace = workspaces[id], let next = workspaces.neighbor(of: id) else { return }
        if let shown = places.first(where: { $0.workspace.id == id }), !leave(shown, for: next) {
            environment.system.beep()
            return
        }
        workspaces.remove(id)
        workspaces.save(to: defaults)
        workspace.forget(in: defaults)
        updateMonitorRepositories()
    }

    /// The window showing a workspace that is being deleted lets go of it: it closes when another main window
    /// stays, else it shows `next`. False when it cannot now (a sheet, a Git action, a draft that cannot be saved).
    private func leave(_ shown: WorkspaceWindow, for next: Workspace) -> Bool {
        if places.count > 1 {
            focus(shown)
            if place === shown, mainWindowShouldClose() { shown.windows.window?.close() }
            return !places.contains { $0 === shown }
        }
        guard canChangeWorkspace, flushCommitDrafts() else { return false }
        replaceWorkspace(with: next)
        return true
    }
}
