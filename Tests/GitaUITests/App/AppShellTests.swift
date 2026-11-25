import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The app shell over a real temporary repository: launch, window, menus, deep links and Git commands.
@MainActor
@Suite("App shell", .serialized)
struct AppShellTests {
    private func launched(_ repository: TemporaryRepository) async -> AppShellHarness {
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        return shell
    }

    private func repository() throws -> TemporaryRepository {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        try repository.commit("README.md", "two\n", message: "Second")
        return repository
    }

    @Test func launchingOpensTheRequestedRepositoryInTheWindow() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let delegate = shell.app
        #expect(delegate.didFinishLaunching)
        #expect(delegate.mainWindow != nil)
        #expect(delegate.tabsController?.count == 1)
        #expect(delegate.statusItem != nil)
        #expect(shell.recorder.policies.contains(.regular))
        #expect(delegate.repositorySession?.repositories.count == 1)
        #expect(!(NSApp.mainMenu?.items.isEmpty ?? true))
        #expect(delegate.panelRepositoryURLs.count == 1)
    }

    @Test func everyMenuItemAndToolbarItemValidates() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let items = AppShellHarness.items(in: NSApp.mainMenu)
        let enabled = items.filter { shell.app.validateMenuItem($0) }
        #expect(enabled.contains { $0.action == #selector(RepositoryCommandResponder.newBranch) })
        #expect(!enabled.contains { $0.action == #selector(RepositoryCommandResponder.continueOperation) })
        let push = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("push"))
        #expect(!shell.app.validateToolbarItem(push))
        let branch = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("branch"))
        #expect(shell.app.validateToolbarItem(branch))
        let remote = try #require(shell.menuItem(#selector(RepositoryCommandResponder.openRemote)))
        _ = shell.app.validateMenuItem(remote)
        #expect(remote.title == String(localized: "Open Remote in Browser"))
    }

    @Test func newBranchAsksForANameAndCreatesIt() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.commands.newBranch()
        #expect(shell.alerts.last?.messageText == String(localized: "New branch"))
        shell.alerts.fields.first?.stringValue = "feature"
        shell.alerts.answer()
        await shell.settle()
        await appWaitUntil {
            (try? repository.git("branch", "--list", "feature"))?.contains("feature") == true
        }
    }

    @Test func aCancelledPromptChangesNothing() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.commands.stash()
        shell.alerts.answer(.alertSecondButtonReturn)
        await shell.settle()
        #expect(try repository.git("stash", "list").isEmpty)
    }

    @Test func stashKeepsTheChangesWithTheMessage() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        try repository.write("README.md", "changed\n")
        shell.app.commands.stash()
        shell.alerts.fields.first?.stringValue = "Parked"
        shell.alerts.answer()
        await appWaitUntil { (try? repository.git("stash", "list"))?.contains("Parked") == true }
    }

    @Test func newBranchFromAStartPointAndCheckingOut() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let first = try repository.git("rev-list", "--max-parents=0", "HEAD").trimmingCharacters(in: .newlines)
        shell.app.commands.newBranchFrom(first, suggestion: "old")
        #expect(shell.alerts.fields.first?.stringValue == "old")
        shell.alerts.answer()
        await shell.settle()
        await appWaitUntil { (try? repository.git("rev-parse", "old"))?.hasPrefix(first) == true }
        shell.app.commands.checkoutReference("main")
        await shell.settle()
        await appWaitUntil {
            (try? repository.git("rev-parse", "--abbrev-ref", "HEAD"))?.hasPrefix("main") == true
        }
    }

    @Test func theBranchSwitcherListsBranchesNewestFirstAndChecksOut() async throws {
        let repository = try repository()
        try repository.git("branch", "other")
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.refreshModel()
        await shell.settle()
        shell.app.commands.switchBranch()
        let palette = try #require(shell.app.palette)
        #expect(palette.state.scope == .branch)
        let branches = { palette.state.rows.compactMap { $0.result?.item } }
        #expect(branches().map(\.title).sorted() == ["main", "other"])
        #expect(branches().first { $0.title == "main" }?.isCurrent == true)
        await appWaitUntil { branches().allSatisfy { !$0.trailing.isEmpty } }
        palette.field.stringValue = "oth"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(branches().map(\.title) == ["other"])
        _ = palette.control(
            palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await appWaitUntil {
            (try? repository.git("rev-parse", "--abbrev-ref", "HEAD"))?.hasPrefix("other") == true
        }
        #expect(Preference.paletteRecents.strings(shell.defaults) == ["branch.refs/heads/other"])
        shell.app.commands.switchBranch()
        let second = try #require(shell.app.palette)
        #expect(second !== palette)
        _ = second.control(
            second.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!second.panel.isVisible)
    }

    @Test func newWorktreeAddsACheckoutBesideTheRepository() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let folder = repository.url.deletingLastPathComponent()
            .appendingPathComponent(repository.url.lastPathComponent + "-wt")
        defer { try? FileManager.default.removeItem(at: folder) }
        shell.app.commands.newWorktree()
        let fields = shell.alerts.fields
        #expect(fields.count == 2)
        fields[0].stringValue = "wt-branch"
        fields[1].stringValue = folder.path
        shell.alerts.answer()
        await appWaitUntil { FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) }
        await shell.settle()
        shell.app.commands.newWorktreeFor(branch: "feature/x")
        #expect(shell.alerts.fields.first?.stringValue.hasSuffix("-feature-x") == true)
        shell.alerts.answer(.alertSecondButtonReturn)
    }

    @Test func mergeAndRebaseAskForTheReferenceThenRun() async throws {
        let repository = try repository()
        try repository.git("checkout", "-q", "-b", "topic")
        try repository.commit("topic.txt", "topic\n", message: "Topic")
        try repository.git("checkout", "-q", "main")
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.commands.mergeReference("refs/heads/topic")
        let picker = try #require(shell.alerts.popUps(NSComboBox.self).first)
        #expect(picker.stringValue.isEmpty || picker.indexOfSelectedItem >= 0)
        shell.alerts.answer()
        await appWaitUntil {
            FileManager.default.fileExists(atPath: repository.url.appendingPathComponent("topic.txt").path)
        }
        await shell.settle()
        shell.app.commands.rebaseBranch()
        shell.alerts.answer(.alertSecondButtonReturn)
        shell.app.commands.mergeBranch()
        shell.alerts.answer(.alertSecondButtonReturn)
        shell.app.commands.rebaseOntoReference("refs/heads/topic")
        shell.alerts.answer(.alertSecondButtonReturn)
    }

    @Test func revertAndCherryPickTheSelectedCommit() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let model = shell.app.model
        let head = try #require(model.snapshot?.commits.first)
        model.select(head)
        await appWaitUntil { model.selectedCommit?.id == head.id }
        shell.app.commands.copyCommit()
        #expect(shell.recorder.pasteboard.string(forType: .string) == head.id)
        shell.app.commands.revertCommit()
        #expect(shell.alerts.last?.informativeText.contains(head.id) == true)
        shell.alerts.answer()
        await appWaitUntil { (try? repository.git("log", "-1", "--format=%s"))?.hasPrefix("Revert") == true }
        await shell.settle()
        shell.app.commands.cherryPickCommit()
        shell.alerts.answer(.alertSecondButtonReturn)
    }

    @Test func zoomAndDetailsAreStoredAndShared() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let key = Preference.historyZoomPercent.rawValue
        shell.app.zoomIn()
        #expect(shell.defaults.integer(forKey: key) == HistoryZoom.actual + HistoryZoom.step)
        shell.app.zoomOut()
        shell.app.zoomOut()
        #expect(shell.defaults.integer(forKey: key) == HistoryZoom.actual - HistoryZoom.step)
        shell.app.actualSize()
        #expect(shell.defaults.integer(forKey: key) == HistoryZoom.actual)
        let details = shell.app.model.showsHistoryDetails
        shell.app.toggleHistoryDetails()
        #expect(shell.app.model.showsHistoryDetails == !details)
        let item = try #require(shell.menuItem(#selector(AppDelegate.toggleHistoryDetails)))
        _ = shell.app.validateMenuItem(item)
        #expect(item.state == (details ? .off : .on))
    }

    @Test func theBuiltInTerminalOpensInTheWindowsPanelAndClosesWithIt() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let tabs = try #require(shell.app.tabsController)
        let panel = tabs.terminalPanel
        panel.defaults = shell.defaults
        #expect(!tabs.isTerminalPanelShown)
        shell.app.toggleTerminal()
        #expect(tabs.isTerminalPanelShown)
        #expect(panel.entries.count == 1)
        let split = try #require(panel.superview as? NSSplitView)
        #expect(abs(panel.frame.height / split.bounds.height - 0.3) < 0.01, "30% of the window the first time")
        // The user drags it to a fifth of the window; it opens there next time. (Smaller rather than larger: the
        // window fits the screen, and on a small one the repository's minimum heights stop the divider short of
        // half.)
        split.setPosition(split.bounds.height * 0.8 - split.dividerThickness, ofDividerAt: 0)
        panel.splitViewDidResizeSubviews(
            Notification(
                name: NSSplitView.didResizeSubviewsNotification, object: split,
                userInfo: ["NSSplitViewDividerIndex": 0]))
        shell.app.toggleTerminal()
        shell.app.toggleTerminal()
        #expect(abs(panel.frame.height / split.bounds.height - 0.2) < 0.01, "where the user left it")
        #expect(panel.selected?.terminal.session.directory.lastPathComponent == repository.url.lastPathComponent)
        let item = try #require(shell.menuItem(#selector(AppDelegate.toggleTerminal)))
        _ = shell.app.validateMenuItem(item)
        #expect(item.state == .on)
        #expect(item.keyEquivalent == "`" && item.keyEquivalentModifierMask == [.control])
        shell.app.toggleTerminal()
        #expect(!tabs.isTerminalPanelShown && panel.entries.count == 1, "hidden, still running")
        shell.app.toggleTerminal()
        #expect(tabs.isTerminalPanelShown && panel.entries.count == 1)
        // View ▸ New Terminal (⌃⇧`): another shell in the repository.
        shell.app.newTerminal()
        #expect(panel.entries.count == 2)
        let new = try #require(shell.menuItem(#selector(AppDelegate.newTerminal)))
        #expect(new.keyEquivalent == "`" && new.keyEquivalentModifierMask == [.control, .shift])
        panel.close(try #require(panel.selectedID))

        // "Review with …" and "Open in Terminal" reach the panel through the app delegate.
        let script = URL(fileURLWithPath: "/tmp/review.command")
        AppOpener.system.openBuiltInTerminal(repository.url, script)
        #expect(panel.entries.count == 2)
        #expect(panel.selected?.title == String(localized: "Review · \(repository.url.lastPathComponent)"))

        let sessions = panel.entries.map(\.terminal.session)
        try #require(shell.app.mainWindow).close()
        #expect(sessions.allSatisfy { $0.state == .closed }, "closing the window ends its terminals")
        #expect(panel.entries.isEmpty)
    }

    @Test func deepLinksChooseAPageAndFoldersOpenTabs() async throws {
        let repository = try repository()
        let other = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let changes = try #require(URL(string: "gita://open/changes"))
        shell.app.application(NSApp, open: [changes])
        #expect(shell.app.model.section == .changes)
        let ignored = try #require(URL(string: "https://example.invalid/x"))
        shell.app.application(NSApp, open: [ignored, other.url])
        await appWaitUntil { shell.app.tabsController?.count == 2 }
        shell.app.previousTab()
        shell.app.nextTab()
        let number = NSMenuItem()
        number.tag = 1
        shell.app.selectTabNumber(number)
        #expect(shell.app.tabsController?.selectedIndex == 0)
        shell.app.newTab()
        #expect(shell.app.tabsController?.count == 3)
        #expect(shell.app.tabsController?.selectedTab?.isWelcome == true)
    }

    @Test func requestsBeforeLaunchWaitAndOpenAfterIt() async throws {
        let repository = try repository()
        let shell = AppShellHarness(arguments: ["Gita"])
        shell.app.application(NSApp, open: [repository.url])
        shell.app.openRepositoryTab(repository.url)
        shell.app.showWindow()
        #expect(shell.app.launch.wantsWindow)
        #expect(shell.app.router.pending.count == 2)
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        #expect(shell.app.router.pending.isEmpty)
        #expect(shell.app.tabsController?.count == 1)
    }

    @Test func terminalsAndAuthorTabsBeforeLaunchAreRefused() throws {
        let shell = AppShellHarness(arguments: ["Gita"])
        let script = try TerminalScriptLauncher.writeScript("#!/bin/sh\n", in: ReviewScripts.folder)
        defer { try? FileManager.default.removeItem(at: script) }
        shell.app.openTerminal(FileManager.default.temporaryDirectory, launch: .script(script))
        #expect(shell.recorder.beeps == 1)
        // The review script will never run: it is removed rather than left in the temporary folder.
        #expect(!FileManager.default.fileExists(atPath: script.path))
        #expect(!shell.app.launch.wantsWindow)
        let commit = GitCommit(
            id: "1", parents: [], subject: "s", author: "Ada", email: "ada@example.invalid", date: Date())
        shell.app.openAuthorTab(CommitAuthor(commit), in: FileManager.default.temporaryDirectory)
        #expect(shell.recorder.beeps == 2)
        #expect(shell.app.mainWindow == nil)
    }

    @Test func theRevealAndRemoteCommandsUseTheSystemHooks() async throws {
        let repository = try repository()
        try repository.git("remote", "add", "origin", "https://github.com/example/repo.git")
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.refreshModel()
        await appWaitUntil { shell.app.model.snapshot?.remoteURL != nil }
        shell.app.commands.reveal()
        #expect(shell.recorder.revealed.count == 1)
        shell.app.commands.openRemote()
        #expect(shell.recorder.webPages.first??.host == "github.com")
        let remote = try #require(shell.menuItem(#selector(RepositoryCommandResponder.openRemote)))
        #expect(shell.app.validateMenuItem(remote))
        #expect(remote.title != String(localized: "Open Remote in Browser"))
    }

    @Test func closingTheWindowKeepsTheRepositoryForTheNextShow() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let window = try #require(shell.app.mainWindow)
        window.performClose(nil)
        #expect(shell.app.mainWindow == nil)
        #expect(shell.app.restingRepository.map { AttentionRequest.sameLocation($0, repository.url) } == true)
        #expect(shell.recorder.policies.last == .accessory)
        shell.app.closeEntireWindow()
        shell.app.showWindow()
        #expect(shell.app.mainWindow != nil)
        _ = shell.app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
    }

    @Test func quittingWithNothingRunningTerminatesAtOnce() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        #expect(shell.app.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(!shell.app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        shell.app.quit()
        #expect(shell.recorder.terminations == 1)
    }

    @Test func activationChangesReachTheModel() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        shell.app.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        shell.app.preferencesDidChange(refreshProviders: false)
        shell.app.removeFromRepositoryList([repository.url.path])
        #expect(shell.app.model.recent.isEmpty)
        #expect(shell.app.recentMenu().items.isEmpty)
    }
}

extension AppDelegate {
    /// Reads the selected repository again (without the providers `refresh()` also reloads).
    func refreshModel() { model.refresh() }
}
