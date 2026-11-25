import AppKit
import GitaCore

/// The app's own commands: opening and closing repositories, tabs and windows, pages, zoom and Quit.
extension AppDelegate {
    /// Where Clone suggests putting a new clone.
    private static let cloneFolder = "Projects/repository"

    @objc func newTab() {
        showWindow()
        tabsController?.openNewTab()
    }

    @objc func openRepository() {
        showWindow()
        guard let mainWindow, tabsController?.canChangeRepository == true else {
            environment.system.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Open Repository")
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: mainWindow) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { self?.openRepositoryTab(url) }
        }
    }

    func openRepositoryTab(_ url: URL) { _ = showRepositoryTab(url) }

    func showRepositoryTab(_ url: URL) -> Bool {
        if isLanguageRestarting {
            application(NSApp, open: [url])
            return true
        }
        guard didFinishLaunching, setupGuide == nil else {
            router.enqueue([url])
            return true
        }
        focusWindow(showing: url)
        showWindow()
        return tabsController?.open(url) == true
    }

    /// Commit menu › author › Filter: that author's commits in a tab of their own.
    func openAuthorTab(_ author: CommitAuthor, in root: URL) {
        guard gate.canOpenWindowContent else {
            environment.system.beep()
            return
        }
        showWindow()
        tabsController?.openAuthor(author, in: root)
    }

    @objc func cloneRepository() {
        showWindow()
        guard tabsController?.canChangeRepository == true else {
            environment.system.beep()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        prompt(
            String(localized: "Clone repository"),
            labels: [String(localized: "Remote URL or local path"), String(localized: "New directory")],
            defaults: ["", home.appendingPathComponent(Self.cloneFolder).path], button: String(localized: "Clone")
        ) { [weak self] values in
            self?.tabsController?.acquire(
                remote: values[0].trimmingCharacters(in: .whitespacesAndNewlines),
                destination: TypedPath.url(values[1]))
        }
    }

    @objc func initializeRepository() {
        showWindow()
        guard let mainWindow, tabsController?.canChangeRepository == true else {
            environment.system.beep()
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "New repository")
        panel.prompt = String(localized: "Create Repository")
        panel.nameFieldStringValue = String(localized: "Repository")
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: mainWindow) { [weak self] result in
            if result == .OK, let url = panel.url {
                DispatchQueue.main.async { self?.tabsController?.acquire(remote: nil, destination: url) }
            }
        }
    }

    /// File › Open Recent: the recently opened repositories, in a menu at the window's top left.
    @objc func openRecent() {
        guard let view = mainWindow?.contentView else { return }
        recentMenu().popUp(positioning: nil, at: NSPoint(x: 20, y: view.bounds.height - 10), in: view)
    }

    func recentMenu() -> NSMenu {
        let menu = NSMenu()
        for path in place.workspace.recent(in: defaults) {
            let row = NSMenuItem(
                title: URL(fileURLWithPath: path).lastPathComponent, action: #selector(openRecentPath(_:)),
                keyEquivalent: "")
            row.target = self
            row.representedObject = path
            menu.addItem(row)
        }
        return menu
    }

    @objc func openRecentPath(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { openRepositoryTab(URL(fileURLWithPath: path)) }
    }

    /// Sidebar ▸ a repository ▸ Remove from List: the repository (and any of its worktrees opened before) leaves its
    /// workspace's recently opened list, and so the sidebar and the menu bar panel at once. Nothing on disk changes;
    /// opening it again lists it again.
    func removeFromRepositoryList(_ paths: [String]) {
        let key = place.workspace.recentKey
        defaults.set(RecentRepositories.removing(paths, from: defaults.stringArray(forKey: key) ?? []), forKey: key)
        RepositorySidebarView.forgetRepositories(paths)
        updateMonitorRepositories()
    }

    /// Refresh (⌘R): the repository, its providers, and Vercel's production and branch context, which scheduled
    /// reads leave cached.
    @objc func refresh() {
        model.refresh()
        model.requestVercelContext()
        model.refreshProviders()
        model.checkRemotesNow()
    }

    @objc func settings() {
        statusItem?.closePanel()
        SettingsWindowController.shared.show()
    }

    @objc func about() {
        statusItem?.closePanel()
        AboutWindowController.shared.show()
    }

    @objc func checkForUpdates() {
        statusItem?.closePanel()
        if updater.pendingVersion != nil {
            updater.installAvailableUpdate()
        } else {
            updater.checkForUpdates()
        }
    }

    func installAvailableUpdate() {
        statusItem?.closePanel()
        updater.installAvailableUpdate()
    }

    @objc func findInHistory() {
        showWindow()
        repositoryController?.focusSearch()
    }

    @objc func showActivity() { ActivityWindowController.shared.show(model: model) }

    /// View › a page (⌥⌘1…); Worktrees & Agents opens or closes the right-hand pane.
    @objc func navigate(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let section = Section(rawValue: raw) else { return }
        if section == .worktrees || section == .agents {
            toggleAgentsPane()
            return
        }
        model.section = section
        showWindow()
    }

    /// View › Commit, Changes, File Tree (⌃⌘1… by default): that tab of the detail pane under All Commits, showing
    /// the pane first when it is hidden.
    @objc func showDetailTab(_ sender: NSMenuItem) {
        guard let tab = DetailTab(rawValue: sender.tag), let controller = repositoryController else { return }
        showWindow()
        if !model.showsHistoryDetails { toggleHistoryDetails() }
        if model.section != .history { model.section = .history }
        controller.selectDetailTab(tab)
    }

    @objc func focusSidebar() {
        showWindow()
        repositoryController?.focusPane(.sidebar)
    }

    @objc func focusHistory() {
        showWindow()
        repositoryController?.focusPane(.history)
    }

    @objc func focusFiles() {
        showWindow()
        repositoryController?.focusPane(.files)
    }

    @objc func focusDiff() {
        showWindow()
        repositoryController?.focusPane(.diff)
    }

    @objc func cyclePaneFocus() {
        showWindow()
        repositoryController?.cyclePaneFocus()
    }

    @objc func blameSelectedFile() {
        showWindow()
        repositoryController?.blameSelectedFile()
    }

    /// File › Close Tab (⌘W): the setup guide or a sheet first, then the selected tab.
    @objc func closeWindow() {
        if let session = setupGuide {
            finishSetupGuide(session.id, choices: nil)
            return
        }
        if repositoryController?.closeReviewSheet() == true { return }
        if let sheet = mainWindow?.attachedSheet {
            sheet.performClose(nil)
            return
        }
        if let tabsController { tabsController.closeSelectedTab() } else { NSApp.keyWindow?.performClose(nil) }
    }

    @objc func closeEntireWindow() { mainWindow?.performClose(nil) }
    @objc func nextTab() { tabsController?.selectNextTab() }
    @objc func previousTab() { tabsController?.selectPreviousTab() }
    @objc func selectTabNumber(_ sender: NSMenuItem) { tabsController?.selectTab(number: sender.tag) }

    @objc func zoomIn() { setZoom(HistoryZoom.zoomedIn(model.historyZoomPercent)) }
    @objc func zoomOut() { setZoom(HistoryZoom.zoomedOut(model.historyZoomPercent)) }
    @objc func actualSize() { setZoom(HistoryZoom.actual) }

    private func setZoom(_ percent: Int) {
        defaults.set(percent, forKey: Preference.historyZoomPercent.rawValue)
        preferencesDidChange()
    }

    @objc func toggleHistoryDetails() {
        defaults.set(!model.showsHistoryDetails, forKey: Preference.showsHistoryDetails.rawValue)
        preferencesDidChange()
    }

    @objc func quit() {
        if isLanguageRestarting { return }
        let terminate = environment.system.terminate
        if let session = setupGuide {
            finishSetupGuide(session.id, choices: nil, resumeNavigation: false)
            DispatchQueue.main.async { terminate() }
            return
        }
        switch TerminationPolicy(hasReviewSheet: reviewingController != nil, isMutating: isAnyMutating) {
        case .refuseWhileMutating: environment.system.beep()
        case .now: terminate()
        case .askReviewSheet:
            dismissReviewSheets { allowed in
                if allowed { DispatchQueue.main.async { terminate() } }
            }
        }
    }
}
