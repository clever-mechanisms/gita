import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Workspaces in the app shell: a new one takes the window (or a window of its own), each keeps its own tabs, and
/// renaming and deleting act on the one in front.
@MainActor
@Suite("App shell: workspaces", .serialized)
struct AppShellWorkspaceTests {
    private func launched(_ repository: TemporaryRepository) async -> AppShellHarness {
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        return shell
    }

    private func repository() throws -> TemporaryRepository {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        return repository
    }

    /// File ▸ Workspace ▸ New Workspace…, named `name`; waits until it is the one in front.
    private func addWorkspace(_ name: String, in shell: AppShellHarness) async {
        shell.app.newWorkspace()
        #expect(shell.alerts.last?.messageText == String(localized: "New workspace"))
        shell.alerts.fields.first?.stringValue = name
        shell.alerts.answer()
        await appWaitUntil { shell.app.place.workspace.name == name }
    }

    private func shows(_ repository: TemporaryRepository, in shell: AppShellHarness) -> Bool {
        shell.app.model.snapshot.map { AttentionRequest.sameLocation($0.root, repository.url) } == true
    }

    @Test func aNewWorkspaceTakesTheWindowAndKeepsItsOwnTabs() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        let window = try #require(app.mainWindow)
        let first = try #require(app.tabsController)
        #expect(app.place.workspace.id == Workspace.firstID)

        app.newWorkspace()
        #expect(shell.alerts.fields.first?.stringValue == String(localized: "Workspace \(2)"))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(app.workspaces.workspaces.count == 1)

        await addWorkspace("Client", in: shell)
        let client = app.place.workspace
        #expect(app.places.count == 1)
        #expect(app.mainWindow === window)
        #expect(app.tabsController !== first)
        #expect(first.isDetached)
        #expect(app.tabsController?.workspace == client)
        #expect(app.tabsController?.openRepositories.isEmpty == true)
        #expect(app.model.snapshot == nil)
        #expect(app.model.recentKey == client.recentKey)
        #expect(WorkspaceList.restore(from: shell.defaults).active == client)
        // The first workspace's tabs were saved under its own key, the new one's under another.
        let saved = RepositoryTabSession.restore(from: shell.defaults)
        #expect(saved?.repositories.count == 1)
        let own = RepositoryTabSession.restore(from: shell.defaults, key: client.sessionKey)
        #expect(own?.repositories.isEmpty == true)

        app.openWorkspace(Workspace.firstID)
        await appWaitUntil { shows(repository, in: shell) }
        #expect(app.mainWindow === window)
        #expect(app.tabsController?.count == 1)
        #expect(app.place.workspace.id == Workspace.firstID)
        #expect(app.panelRepositoryURLs.count == 1)
        // The panel lists both: the one in the window with its tab, the other closed, with the tabs it saved.
        let listed = app.panelWorkspaces
        #expect(listed.map(\.id) == [Workspace.firstID, client.id])
        #expect(listed.map(\.presence) == [.front, .closed])
        #expect(listed.map(\.title) == [String(localized: "Default"), "Client"])
        let tab = RepositoryTabSession.canonical(repository.url)
        #expect(listed[0].repositories == [MenuPanelState.Repository.id(tab)])
        #expect(listed[1].repositories.isEmpty)
    }

    @Test func thePanelListsAClosedWorkspacesSavedTabs() async throws {
        let repository = try repository()
        let other = try self.repository()
        let settings = AppTestDefaults()
        var list = WorkspaceList()
        let client = try addedWorkspace("Client", to: &list)
        list.save(to: settings.defaults)
        RepositoryTabSession(repositories: [other.url]).save(to: settings.defaults, key: client.sessionKey)
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path], settings: settings)
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        let app = shell.app
        let saved = MenuPanelState.Repository.id(RepositoryTabSession.canonical(other.url))
        #expect(app.panelWorkspaces.map(\.presence) == [.front, .closed])
        #expect(app.panelWorkspaces[1].repositories == [saved])
        // Its tabs are followed, so their pills have a status.
        #expect(app.panelRepositoryURLs.map(MenuPanelState.Repository.id).contains(saved))
        // With its window closed the front workspace rests: it keeps its tabs, listed once each, and a pill
        // opens the window on its tab.
        app.mainWindow?.performClose(nil)
        #expect(app.mainWindow == nil)
        #expect(app.panelWorkspaces.map(\.presence) == [.resting, .closed])
        #expect(app.panelWorkspaces[0].repositories.count == 1)
        app.panelActions.showTab(repository.url, Workspace.firstID)
        #expect(app.mainWindow != nil)
        #expect(app.panelWorkspaces.map(\.presence) == [.front, .closed])
        app.mainWindow?.performClose(nil)

        // New Workspace… from the panel, without a main window: the window opens for the sheet.
        app.panelActions.newWorkspace()
        #expect(app.mainWindow != nil)
        #expect(shell.alerts.last?.messageText == String(localized: "New workspace"))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(app.panelWorkspaces.map(\.presence) == [.front, .closed])
        // Open on the closed card: the workspace takes the window.
        app.panelActions.openWorkspace(client.id)
        await appWaitUntil { app.place.workspace == client }
        #expect(app.panelWorkspaces.map(\.presence) == [.closed, .front])
    }

    @Test func choosingTheWorkspaceInFrontOnlyShowsItsWindow() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let tabs = try #require(shell.app.tabsController)
        shell.app.openWorkspace(Workspace.firstID)
        shell.app.openWorkspace("unknown")
        #expect(shell.app.tabsController === tabs)
        #expect(shell.recorder.beeps == 0)
    }

    @Test func aWorkspaceOpensInAWindowOfItsOwnWhenSettingsSaySo() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        shell.defaults.set(true, forKey: Preference.workspaceWindows.rawValue)
        let firstWindow = try #require(app.mainWindow)
        let firstTabs = try #require(app.tabsController)

        await addWorkspace("Client", in: shell)
        let client = app.place.workspace
        #expect(app.places.count == 2)
        let secondWindow = try #require(app.mainWindow)
        #expect(secondWindow !== firstWindow)
        #expect(!firstTabs.isDetached)
        #expect(app.tabsController?.workspace == client)
        #expect(secondWindow.title == String(localized: "\("Client") — Gitā"))
        #expect(app.panelRepositoryURLs.count == 1)
        // The panel lists the one in front and the one in the window behind.
        #expect(app.panelWorkspaces.map(\.presence) == [.window, .front])
        #expect(app.panelWorkspaces.map(\.id) == [Workspace.firstID, client.id])
        // Both are in a window: the menu marks the one behind, and choosing it brings its window forward.
        let items = app.workspaceMenuItems()
        #expect(items[0].image != nil)
        #expect(items[1].state == .on)
        app.openWorkspace(Workspace.firstID)
        #expect(app.places.count == 2)
        #expect(app.mainWindow === firstWindow)
        #expect(app.tabsController === firstTabs)
        #expect(shows(repository, in: shell))
        #expect(WorkspaceList.restore(from: shell.defaults).active.id == Workspace.firstID)

        // A repository asked for from outside (a link, a notification) shows in the window that has it open.
        app.openWorkspace(client.id)
        #expect(app.mainWindow === secondWindow)
        app.openRepositoryTab(repository.url)
        #expect(app.mainWindow === firstWindow)
        #expect(app.tabsController?.count == 1)
        #expect(app.places[1].tabs?.openRepositories.isEmpty == true)
        // A pill of a workspace that has no window any more: the repository shows where it is open.
        app.panelActions.showTab(repository.url, "gone")
        #expect(app.mainWindow === firstWindow)
        // A pill shows its repository's tab in its own workspace's window, even while another has it open.
        app.panelActions.showTab(repository.url, client.id)
        #expect(app.mainWindow === secondWindow)
        await appWaitUntil { app.places[1].tabs?.openRepositories.count == 1 }
        #expect(app.panelWorkspaces[1].repositories.count == 1)
        app.panelActions.showTab(repository.url, Workspace.firstID)
        #expect(app.mainWindow === firstWindow)
        #expect(app.tabsController?.count == 1)

        // Closing a workspace's own window lets its place go; the shell stays with the window that is left.
        secondWindow.close()
        #expect(app.places.count == 1)
        #expect(app.mainWindow === firstWindow)
        // The last window's place stays for the next show.
        firstWindow.close()
        #expect(app.places.count == 1)
        #expect(app.mainWindow == nil)
        app.openWorkspace(client.id)
        #expect(app.places.count == 1)
        #expect(app.place.workspace == client)
        #expect(app.mainWindow != nil)
    }

    @Test func closingTheWindowInFrontMovesTheShellToTheOther() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        shell.defaults.set(true, forKey: Preference.workspaceWindows.rawValue)
        let firstWindow = try #require(app.mainWindow)
        await addWorkspace("Client", in: shell)
        #expect(app.places.count == 2)
        #expect(app.isAnyMutating == false)
        #expect(app.reviewingController == nil)
        #expect(app.flushAllCommitDrafts())
        app.preferencesDidChange()
        // The window behind is asked to close: it becomes the one the shell acts on, then goes.
        #expect(app.places[0].windows.shouldClose())
        #expect(app.mainWindow === firstWindow)
        firstWindow.close()
        #expect(app.places.count == 1)
        #expect(app.place.workspace.name == "Client")
    }

    @Test func renamingShowsTheNewNameInTheTabBarAndTheWindowTitle() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        let tabs = try #require(app.tabsController)
        let name = repository.url.lastPathComponent
        #expect(tabs.windowTitle(repository: name) == String(localized: "\(name) — Gitā"))
        #expect(tabs.windowTitle(repository: nil) == "Gitā")
        #expect(RepositoryTabsController.buttonTitle("Work") == "Work")
        #expect(RepositoryTabsController.buttonTitle(String(repeating: "x", count: 30)).count == 22)
        #expect(tabs.workspaceButton.accessibilityValue() as? String == String(localized: "Default"))

        app.renameWorkspace()
        #expect(shell.alerts.last?.messageText == String(localized: "Rename workspace"))
        #expect(shell.alerts.fields.first?.stringValue == String(localized: "Default"))
        shell.alerts.fields.first?.stringValue = "  "
        shell.alerts.answer()
        #expect(shell.recorder.beeps == 1)
        #expect(app.place.workspace.name == nil)

        app.renameWorkspace()
        shell.alerts.fields.first?.stringValue = "Work"
        shell.alerts.answer()
        #expect(app.place.workspace.title == "Work")
        #expect(tabs.workspace.title == "Work")
        #expect(tabs.workspaceButton.accessibilityValue() as? String == "Work")
        #expect(app.mainWindow?.title == String(localized: "\(name) — \("Work") — Gitā"))
        #expect(WorkspaceList.restore(from: shell.defaults).active.title == "Work")
        // The button's menu is the Workspace menu.
        #expect(tabs.workspaceMenu?()?.items.first?.title == "Work")
    }

    @Test func deletingTheWorkspaceInFrontShowsItsNeighbourAndForgetsItsTabs() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        // The only workspace stays.
        app.deleteWorkspace()
        #expect(shell.recorder.beeps == 1)
        #expect(shell.alerts.alerts.isEmpty)

        await addWorkspace("Client", in: shell)
        let client = app.place.workspace
        #expect(shell.defaults.object(forKey: client.sessionKey) != nil)
        app.deleteWorkspace()
        #expect(shell.alerts.last?.messageText == String(localized: "Delete the workspace “\("Client")”?"))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(app.workspaces.workspaces.count == 2)

        app.deleteWorkspace()
        shell.alerts.answer()
        await appWaitUntil { app.workspaces.workspaces.count == 1 }
        #expect(app.place.workspace.id == Workspace.firstID)
        #expect(shell.defaults.object(forKey: client.sessionKey) == nil)
        #expect(WorkspaceList.restore(from: shell.defaults).workspaces.map(\.id) == [Workspace.firstID])
        await appWaitUntil { shows(repository, in: shell) }
    }

    @Test func deletingAWorkspaceInItsOwnWindowClosesThatWindow() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        shell.defaults.set(true, forKey: Preference.workspaceWindows.rawValue)
        let firstWindow = try #require(app.mainWindow)
        await addWorkspace("Client", in: shell)
        app.deleteWorkspace()
        shell.alerts.answer()
        await appWaitUntil { app.workspaces.workspaces.count == 1 }
        #expect(app.places.count == 1)
        #expect(app.mainWindow === firstWindow)
        #expect(app.place.workspace.id == Workspace.firstID)
    }

    @Test func aBusyWindowKeepsItsWorkspace() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        var list = app.workspaces
        let other = try addedWorkspace("Other", to: &list)
        app.workspaces = list
        let window = try #require(app.mainWindow)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        #expect(!app.canChangeWorkspace)
        app.openWorkspace(other.id)
        app.newWorkspace()
        app.renameWorkspace()
        app.deleteWorkspace()
        #expect(shell.recorder.beeps == 4)
        #expect(app.place.workspace.id == Workspace.firstID)
        #expect(app.workspaceMenuItems().dropFirst(2).allSatisfy { $0.isSeparatorItem || !$0.isEnabled })
        window.endSheet(sheet)
    }

    @Test func closingAWindowWithOpenTerminalsAsksFirst() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        let panel = try #require(app.tabsController?.terminalPanel)
        panel.defaults = shell.defaults
        #expect(app.windows.shouldClose())
        app.newTerminal()
        app.newTerminal()
        #expect(panel.openCount == 2)

        #expect(!app.windows.shouldClose())
        #expect(shell.alerts.last?.messageText == String(localized: "Close the window?"))
        #expect(shell.alerts.last?.informativeText == AppDelegate.openTerminalsWarning(2))
        #expect(AppDelegate.openTerminalsWarning(1) != AppDelegate.openTerminalsWarning(2))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(app.mainWindow != nil)
        #expect(panel.entries.count == 2)

        #expect(!app.windows.shouldClose())
        shell.alerts.answer()
        await appWaitUntil { app.mainWindow == nil }
        #expect(panel.entries.isEmpty)
    }

    @Test func switchingWorkspaceWithOpenTerminalsAsksFirst() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let app = shell.app
        var list = app.workspaces
        let other = try addedWorkspace("Other", to: &list)
        app.workspaces = list
        let panel = try #require(app.tabsController?.terminalPanel)
        panel.defaults = shell.defaults
        app.newTerminal()

        app.openWorkspace(other.id)
        #expect(shell.alerts.last?.messageText == String(localized: "Switch to “\("Other")”?"))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(app.place.workspace.id == Workspace.firstID)
        #expect(panel.openCount == 1)
        // Deleting says that the terminal closes too.
        app.deleteWorkspace()
        #expect(shell.alerts.last?.informativeText.contains(AppDelegate.openTerminalsWarning(1)) == true)
        shell.alerts.answer(.alertSecondButtonReturn)

        app.openWorkspace(other.id)
        shell.alerts.answer()
        await appWaitUntil { app.place.workspace == other }
        #expect(panel.entries.isEmpty)
        #expect(app.mainWindow != nil)
    }

    @Test func theFileMenuListsTheWorkspaces() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let item = try #require(
            AppShellHarness.items(in: NSApp.mainMenu).first { $0.title == String(localized: "Workspace") })
        let menu = try #require(item.submenu)
        await addWorkspace("Client", in: shell)
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.items.map(\.title).prefix(2) == [String(localized: "Default"), "Client"])
        #expect(menu.items[1].state == .on)
        #expect(menu.items.last?.title == String(localized: "Delete “\("Client")”…"))
    }

    @Test func theLastWorkspaceInFrontOpensAtTheNextLaunch() async throws {
        let repository = try repository()
        let settings = AppTestDefaults()
        var list = WorkspaceList()
        let client = try addedWorkspace("Client", to: &list)
        list.activate(client.id)
        list.save(to: settings.defaults)
        RepositoryTabSession(repositories: [repository.url]).save(to: settings.defaults, key: client.sessionKey)
        let shell = AppShellHarness(settings: settings)
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        #expect(shell.app.place.workspace == client)
        #expect(shell.app.tabsController?.count == 1)
        // Its recent repositories are its own: the repository it opened is listed there, not in the first
        // workspace's list, and that list is not shown here.
        let name = repository.url.lastPathComponent
        #expect(shell.app.recentMenu().items.map(\.title) == [name])
        #expect(Preference.recentRepositories.strings(shell.defaults).isEmpty)
        shell.defaults.set(["/r/elsewhere"], forKey: Preference.recentRepositories.rawValue)
        #expect(shell.app.recentMenu().items.map(\.title) == [name])
        // The menu bar panel follows every workspace's repositories.
        #expect(shell.app.panelRepositoryURLs.map(\.path).contains("/r/elsewhere"))
        shell.app.removeFromRepositoryList(client.recent(in: shell.defaults))
        #expect(client.recent(in: shell.defaults).isEmpty)
        #expect(Preference.recentRepositories.strings(shell.defaults) == ["/r/elsewhere"])
    }
}
