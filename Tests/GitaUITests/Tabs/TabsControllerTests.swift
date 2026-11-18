import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Tabs: controller opening, selecting and closing")
struct TabsControllerTests {
    @Test func startsWithOneEmptyTab() throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        #expect(controller.count == 1)
        #expect(!controller.isEmpty)
        #expect(controller.selectedRepository == nil)
        #expect(controller.selectedModel === harness.initialModel)
        #expect(controller.session == RepositoryTabSession())
        #expect(controller.openRepositories.isEmpty)
        #expect(controller.canChangeRepository)
        #expect(!controller.isMutating)
        #expect(controller.flushCommitDrafts())
        #expect(harness.recorder.agentStarts == 1)
        #expect(controller.selectedController === controller.tabs[0].controller)
        // Each repository view gets the tabs around it, not a lookup through its parent.
        #expect(controller.selectedController.tabs === controller)
        controller.viewDidAppear()
        #expect(harness.window.titlebarAppearsTransparent)
    }

    @Test func restoresASavedSession() throws {
        let folders = try TabsFolders()
        let (alpha, beta, gamma) = (try folders.url("alpha"), try folders.url("beta"), try folders.url("gamma"))
        let group = TabGroup(id: UUID(), name: "Pair", color: .green, collapsed: false)
        let saved = RepositoryTabSession(
            repositories: [alpha, beta, gamma], selected: beta, colors: [(gamma, .red)],
            groups: [(group, [alpha, gamma])])
        let harness = try TabsHarness(session: saved, folders: folders)
        let controller = harness.controller
        // The group's tabs sit together.
        #expect(harness.names() == ["alpha", "gamma", "beta"])
        #expect(controller.selectedRepository == beta)
        #expect(controller.groupID(of: controller.tabs[0]) == group.id)
        #expect(controller.tabs[1].color == .red)
        // Only the selected tab reads its repository.
        #expect(harness.recorder.opened.map(\.url) == [beta])
        #expect(controller.session.repositories == [alpha, gamma, beta])
        #expect(controller.session.tabGroups.first?.members == [alpha, gamma])
        // Choosing a tab that has not been read yet reads it first.
        controller.open(alpha)
        #expect(harness.recorder.opened.map(\.url) == [beta, alpha])
        #expect(controller.pendingTab === controller.tabs[0])
        #expect(controller.loadingCheckouts.contains(alpha.path))
        // Asking again while it reads changes nothing.
        controller.open(alpha)
        #expect(controller.selectedRepository == beta)
        TabsHarness.show(controller.tabs[0].model, at: alpha)
        controller.finishPending(controller.tabs[0])
        #expect(controller.selectedRepository == alpha)
        #expect(controller.loadingCheckouts.isEmpty)
    }

    @Test func restoresTheInitialModelsRepository() throws {
        let folders = try TabsFolders()
        let alpha = try folders.url("alpha")
        let harness = try TabsHarness(initialURL: alpha, folders: folders)
        #expect(harness.controller.selectedRepository == alpha)
        #expect(harness.controller.selectedModel === harness.initialModel)
        #expect(harness.recorder.opened.first?.model === harness.initialModel)
    }

    @Test func opensRepositoriesInTheBackgroundThenSwitches() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta"])
        #expect(harness.names() == ["alpha", "beta"])
        #expect(controller.selectedIndex == 1)
        #expect(harness.window.title == "beta — Gitā")
        #expect(harness.sessions.last?.repositories.count == 2)
        // An open repository is selected, not opened again.
        controller.open(try harness.url("alpha"))
        #expect(controller.selectedIndex == 0)
        #expect(harness.recorder.opened.count == 2)
        // A repository that fails to open still takes over, so its error shows.
        controller.open(try harness.url("gamma"))
        let failing = try #require(controller.pendingTab)
        #expect(controller.selectedIndex == 0)
        failing.model.emit(.status)
        #expect(controller.selectedIndex == 2)
        #expect(controller.pendingTab == nil)
    }

    @Test func aSwitchHeldUpByAGitActionHappensWhenItEnds() throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha"])
        controller.open(try harness.url("beta"))
        let pending = try #require(controller.pendingTab)
        let current = controller.selectedModel
        current.isMutating = true
        TabsHarness.show(pending.model, at: try harness.url("beta"))
        controller.finishPending(pending)
        // The current tab stays while its Git action runs; the switch is kept, not dropped.
        #expect(controller.selectedRepository == (try harness.url("alpha")))
        #expect(controller.pendingSwitch == .blocked(pending.id))
        #expect(controller.loadingCheckouts.contains((try harness.url("beta")).path))
        current.isMutating = false
        current.emit(.status)
        #expect(controller.selectedRepository == (try harness.url("beta")))
        #expect(controller.pendingSwitch == .none)
        #expect(controller.loadingCheckouts.isEmpty)
    }

    @Test func aSwitchHeldUpIsTriedAgainWhenASheetEnds() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha"])
        controller.open(try harness.url("beta"))
        let pending = try #require(controller.pendingTab)
        controller.selectedModel.isMutating = true
        TabsHarness.show(pending.model, at: try harness.url("beta"))
        controller.finishPending(pending)
        #expect(controller.pendingSwitch == .blocked(pending.id))
        // Whatever held it up has gone; a sheet that ends is the cue to try again.
        controller.selectedModel.isMutating = false
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: harness.window)
        try await TabsHarness.until { controller.pendingSwitch == .none }
        #expect(controller.selectedRepository == (try harness.url("beta")))
    }

    @Test func choosingAnotherTabDropsAHeldUpSwitch() throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta"])
        controller.open(try harness.url("gamma"))
        let pending = try #require(controller.pendingTab)
        controller.selectedModel.isMutating = true
        TabsHarness.show(pending.model, at: try harness.url("gamma"))
        controller.finishPending(pending)
        controller.selectedModel.isMutating = false
        controller.select(0)
        #expect(controller.pendingSwitch == .none)
        pending.model.emit(.status)
        #expect(controller.selectedIndex == 0)
    }

    @Test func aDuplicateTabGivesWayToTheOpenOne() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta"])
        controller.open(try harness.url("link"))
        let duplicate = try #require(controller.pendingTab)
        TabsHarness.show(duplicate.model, at: try harness.url("alpha"))
        try await TabsHarness.until { controller.count == 2 }
        #expect(controller.selectedRepository == (try harness.url("alpha")))
        #expect(controller.pendingTab == nil)
        // A background duplicate goes without taking the selection.
        controller.select(1)
        controller.openInBackground(AppModel(), url: try harness.url("other"))
        let hidden = controller.tabs[2]
        controller.select(0)
        TabsHarness.show(hidden.model, at: try harness.url("beta"))
        controller.mergeDuplicate(hidden)
        #expect(controller.count == 2)
        #expect(controller.selectedIndex == 0)
    }

    @Test func authorTabsOpenOncePerAuthor() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        let tabs = try harness.openLoaded(["alpha"])
        let commit = GitCommit(
            id: "1", parents: [], subject: "s", author: "Ada", email: "ada@example.invalid", date: Date())
        let author = CommitAuthor(commit)
        let root = try #require(tabs.first?.root)
        controller.openAuthor(author, in: root)
        let authorTab = try #require(controller.pendingTab)
        #expect(authorTab.author == author)
        #expect(authorTab.repositoryRoot == nil)
        TabsHarness.show(authorTab.model, at: root)
        try await TabsHarness.until { controller.selectedIndex == 1 }
        #expect(controller.count == 2)
        #expect(controller.openRepositories == [root])
        #expect(controller.session.repositories == [root])
        #expect(authorTab.button.shown?.name == "alpha [Ada]")
        controller.select(0)
        controller.openAuthor(author, in: root)
        #expect(controller.selectedIndex == 1)
        #expect(controller.count == 2)
    }

    @Test func closingTabs() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta", "gamma"])
        controller.close(at: 0)
        #expect(harness.names() == ["beta", "gamma"])
        #expect(controller.selectedRepository?.lastPathComponent == "gamma")
        controller.closeSelectedTab()
        #expect(harness.names() == ["beta"])
        controller.close(at: 5)
        controller.closeSelectedTab()
        #expect(harness.lastClosed == 1)
        #expect(controller.count == 1)
    }

    @Test func busyTabsBlockChanges() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta"])
        controller.selectedModel.isMutating = true
        #expect(controller.isMutating)
        #expect(!controller.canChangeRepository)
        #expect(!controller.open(try harness.url("gamma")))
        controller.select(0)
        controller.close(at: 0)
        controller.openAuthor(
            CommitAuthor(GitCommit(id: "1", parents: [], subject: "s", author: "A", date: Date())),
            in: try harness.url("alpha"))
        controller.acquire(remote: nil, destination: try harness.url("new"))
        #expect(controller.count == 2)
        #expect(controller.selectedIndex == 1)
        let menu = controller.menu(for: controller.tabs[1])
        #expect(try !TabsHarness.item("Close Tab", in: menu).isEnabled)
        controller.selectedModel.isMutating = false
    }

    @Test func selectingWithKeys() async throws {
        let harness = try TabsHarness()
        let controller = harness.controller
        try harness.openLoaded(["alpha", "beta", "gamma"])
        controller.selectNextTab()
        #expect(controller.selectedIndex == 0)
        controller.selectPreviousTab()
        #expect(controller.selectedIndex == 2)
        controller.selectTab(number: 1)
        #expect(controller.selectedIndex == 0)
        controller.selectTab(number: 9)
        #expect(controller.selectedIndex == 2)
        controller.selectTab(number: 5)
        controller.selectTab(number: 0)
        #expect(controller.selectedIndex == 2)
        // Choosing the selected tab again only marks its agents seen (once the window shows).
        controller.setWindowVisible(true)
        let seen = harness.recorder.seen.count
        controller.select(2)
        #expect(harness.recorder.seen.count == seen + 1)
        controller.setWindowVisible(false)
        controller.refreshSharedPreferences()
        controller.updateLoading()
    }
}
