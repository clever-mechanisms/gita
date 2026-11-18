import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The shell's cross-window flows: language restart, the login offer, a notification's result, the menu bar panel
/// and the operation in progress.
@MainActor
@Suite("App shell flows", .serialized)
struct AppShellFlowTests {
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

    // MARK: Language restart

    @Test func aLanguageRestartOpensTheReplacementAndQuitsWhenItStarts() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.restartForLanguage()
        #expect(shell.app.isLanguageRestarting)
        #expect(shell.recorder.replacements.first?.first == RelaunchTicketStore.argument)
        #expect(shell.app.mainWindow?.attachedSheet != nil)
        let menu = try #require(shell.menuItem(#selector(RepositoryCommandResponder.newBranch)))
        #expect(!shell.app.validateMenuItem(menu))
        // Requests meanwhile go to the replacement.
        shell.app.application(NSApp, open: [repository.url])
        shell.app.openRepositoryTab(repository.url)
        shell.app.quit()
        #expect(shell.recorder.terminations == 0)
        shell.recorder.replacementDone?(nil)
        await appWaitUntil { shell.recorder.terminations == 1 }
    }

    @Test func aFailedLanguageRestartTellsTheUserAndReopensTheShell() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.restartForLanguage()
        shell.recorder.replacementDone?("It broke")
        #expect(shell.app.isLanguageRestarting)
        await appWaitUntil { shell.alerts.last?.informativeText == "It broke" }
        shell.alerts.answer()
        await appWaitUntil { !shell.app.isLanguageRestarting }
        #expect(shell.app.mainWindow?.attachedSheet == nil)
        #expect(shell.app.model.events.contains { $0.failed })
    }

    @Test func aRefusedQuitLeavesTheLanguageHandOver() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.restartForLanguage()
        shell.recorder.replacementDone?(nil)
        await appWaitUntil { shell.recorder.terminations == 1 }
        #expect(shell.app.isLanguageRestarting)
        // The quit the hand-over asked for is refused (a Git action started meanwhile).
        shell.app.model.isMutating = true
        #expect(shell.app.applicationShouldTerminate(NSApp) == .terminateCancel)
        shell.app.model.isMutating = false
        #expect(!shell.app.isLanguageRestarting)
        // The ticket is withdrawn, so the waiting replacement quits instead of taking over.
        #expect(shell.defaults.data(forKey: RelaunchTicketStore.key) == nil)
        shell.app.application(NSApp, open: [repository.url])
        #expect(shell.app.router.pending.isEmpty)
    }

    @Test func aLanguageHandOverThatNeverQuitsTimesOut() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.languageRestartTimeouts.handover = .milliseconds(50)
        shell.app.restartForLanguage()
        shell.recorder.replacementDone?(nil)
        await appWaitUntil { shell.recorder.terminations == 1 }
        await appWaitUntil { !shell.app.isLanguageRestarting }
        #expect(shell.defaults.data(forKey: RelaunchTicketStore.key) == nil)
        #expect(shell.app.mainWindow?.attachedSheet == nil)
    }

    @Test func aReplacementThatDoesNotOpenInTimeFails() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.languageRestartTimeouts.replacement = .milliseconds(50)
        shell.app.restartForLanguage()
        await appWaitUntil { shell.alerts.last?.messageText == "Restart failed" }
        // A late answer from the replacement no longer quits.
        shell.recorder.replacementDone?(nil)
        shell.alerts.answer()
        await appWaitUntil { !shell.app.isLanguageRestarting }
        #expect(shell.recorder.terminations == 0)
    }

    @Test func aLanguageRestartWaitsForAQuietWindow() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.recorder.needsRestart = false
        shell.app.restartForLanguage()
        #expect(shell.recorder.beeps == 1)
        #expect(shell.recorder.replacements.isEmpty)
    }

    @Test func aNotificationResultStopsAWaitingRestart() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.restartForLanguage()
        shell.app.requestAttention(Self.request(for: repository.url, provider: .orca))
        #expect(!shell.app.isLanguageRestarting)
    }

    @Test func aReplacementLaunchesOnceItsPredecessorQuits() async throws {
        let settings = AppTestDefaults()
        let store = RelaunchTicketStore(defaults: settings.defaults, processIdentifier: 4_242)
        let ticket = try #require(store.begin())
        #expect(store.queue([URL(fileURLWithPath: "/tmp")], for: ticket))
        let shell = AppShellHarness(arguments: ["Gita", RelaunchTicketStore.argument, ticket.token.uuidString])
        shell.settings.defaults.set(
            settings.defaults.data(forKey: RelaunchTicketStore.key), forKey: RelaunchTicketStore.key)
        shell.app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { shell.tearDown() }
        await appWaitUntil { shell.app.didFinishLaunching }
        #expect(shell.recorder.terminations == 0)
    }

    @Test func aReplacementWithoutAValidTicketQuits() {
        let shell = AppShellHarness(arguments: ["Gita", RelaunchTicketStore.argument, UUID().uuidString])
        shell.app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(shell.recorder.terminations == 1)
        #expect(!shell.app.didFinishLaunching)
    }

    // MARK: Login offer

    @Test func theLoginOfferAppearsInASettledWindowAndRemembersTheAnswer() async throws {
        let repository = try repository()
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        shell.recorder.offersLogin = true
        shell.recorder.loginResult = .success(.requiresApproval)
        shell.defaults.set(SetupGuideState.version, forKey: SetupGuideState.defaultsKey)
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        guard shell.app.windows.isInFront else { return } // An occluded test display shows no offer.
        shell.app.loginOffer.update()
        await appWaitUntil { shell.app.loginOffer.isShown }
        let offer = try #require(shell.app.loginOffer.offer)
        let enable = try #require(AppRecordingAlerts.views(of: NSButton.self, in: offer).last)
        enable.performClick(nil)
        #expect(!shell.app.loginOffer.isShown)
        #expect(shell.recorder.loginSettingsOpened == 1)
        #expect(Preference.loginItemOfferAnswered.bool(shell.defaults))
    }

    @Test func theLoginOfferHidesWhenTheAppIsInactive() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.recorder.offersLogin = true
        shell.recorder.isActive = false
        shell.app.loginOffer.update()
        #expect(!shell.app.loginOffer.isShown)
        shell.app.loginOffer.hide()
    }

    // MARK: A notification's result

    private static func request(for root: URL, provider: ProviderKind, sourceID: String? = nil) -> AttentionRequest {
        let item = ProviderItem(
            id: "1", provider: provider, category: "Workflow", title: "Build", state: .success, commit: nil,
            branch: "main", url: nil, kind: .workflowRun, target: nil)
        return AttentionRequest(
            repository: root, commonGitDirectory: root.appendingPathComponent(".git"), sourceID: sourceID, item: item)
    }

    @Test func aResultOfAVanishedRepositoryFails() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-gone-\(UUID())")
        shell.app.requestAttention(Self.request(for: gone, provider: .orca))
        #expect(shell.app.attention.pending == nil)
        #expect(shell.app.model.events.contains { $0.failed })
    }

    @Test func anOrcaResultIsVerifiedAndShown() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.requestAttention(Self.request(for: repository.url, provider: .orca))
        await appWaitUntil { shell.app.attention.pending == nil }
        #expect(shell.app.attention.task == nil)
    }

    @Test func aGitHubResultWithAnotherConnectionFails() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.requestAttention(Self.request(for: repository.url, provider: .github, sourceID: "elsewhere"))
        await appWaitUntil { shell.app.attention.pending == nil }
        #expect(shell.app.model.events.contains { $0.failed })
    }

    @Test func aResultOfARepositoryNotOpenYetWaitsForItsTab() async throws {
        let repository = try repository()
        let other = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.requestAttention(Self.request(for: other.url, provider: .orca))
        // Its tab is read in the background first; the result waits for it instead of failing.
        #expect(shell.app.attention.pending != nil)
        await appWaitUntil { shell.app.attention.pending == nil }
        #expect(
            shell.app.tabsController?.selectedRepository.map { AttentionRequest.sameLocation($0, other.url) } == true)
        let failures = shell.app.tabsController?.tabs.flatMap { tab in
            tab.model.events.filter { $0.title == "Open result failed" }
        }
        #expect(failures?.isEmpty == true)
        #expect(!shell.alerts.alerts.contains { $0.messageText == "Open result" })
    }

    @Test func choosingAnotherRepositoryWhileTheResultsTabOpensCancelsIt() async throws {
        let repository = try repository()
        let other = try self.repository()
        let third = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let tabs = try #require(shell.app.tabsController)
        shell.app.requestAttention(Self.request(for: other.url, provider: .orca))
        tabs.open(third.url)
        await appWaitUntil { tabs.selectedRepository.map { AttentionRequest.sameLocation($0, third.url) } == true }
        #expect(shell.app.attention.pending == nil)
        #expect(!shell.alerts.alerts.contains { $0.messageText == "Open result" })
    }

    @Test func aResultRequestedBeforeLaunchWaits() async throws {
        let repository = try repository()
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        shell.app.requestAttention(Self.request(for: repository.url, provider: .orca))
        #expect(shell.app.attention.pending != nil)
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        await appWaitUntil { shell.app.attention.pending == nil }
    }

    // MARK: The menu bar panel

    @Test func thePanelOpensListsTheRepositoryAndCloses() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let statusItem = try #require(shell.app.statusItem)
        shell.app.togglePanel()
        #expect(statusItem.isPanelShown)
        let actions = shell.app.panelActions
        actions.refresh()
        actions.push(repository.url)
        await shell.settle()
        shell.app.selectPanelRepository(repository.url)
        shell.app.togglePanel()
        await appWaitUntil { !statusItem.isPanelShown }
        actions.openApp()
        #expect(shell.app.mainWindow != nil)
    }

    @Test func choosingARepositoryInThePanelWithoutAWindowKeepsItForLater() async throws {
        let repository = try repository()
        let other = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.mainWindow?.performClose(nil)
        shell.app.selectPanelRepository(other.url)
        #expect(shell.app.restingRepository.map { AttentionRequest.sameLocation($0, other.url) } == true)
        #expect(shell.app.repositorySession?.repositories.count == 2)
        shell.app.panelVisibilityChanged()
    }

    // MARK: The operation in progress

    @Test func aConflictedMergeCanBeAborted() async throws {
        let repository = try repository()
        try repository.git("checkout", "-q", "-b", "topic")
        try repository.commit("README.md", "topic\n", message: "Topic")
        try repository.git("checkout", "-q", "main")
        try repository.commit("README.md", "main\n", message: "Main")
        _ = try? repository.git("merge", "topic")
        let shell = await launched(repository)
        defer { shell.tearDown() }
        #expect(shell.app.model.snapshot?.operation != nil)
        let abort = try #require(shell.menuItem(#selector(RepositoryCommandResponder.abortOperation)))
        #expect(shell.app.validateMenuItem(abort))
        shell.app.commands.continueOperation()
        shell.app.commands.skipOperation()
        shell.app.commands.abortOperation()
        #expect(shell.alerts.last?.messageText.isEmpty == false)
        shell.alerts.answer()
        await appWaitUntil {
            !FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/MERGE_HEAD").path)
        }
    }
}
