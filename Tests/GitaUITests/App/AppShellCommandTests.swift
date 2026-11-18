import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The setup guide, the login offer and the app's own commands (closing, quitting, recent repositories, pages).
@MainActor
@Suite("App shell commands", .serialized)
struct AppShellCommandTests {
    private func launched(_ repository: TemporaryRepository, isDevelopment: Bool = true) async -> AppShellHarness {
        let shell = AppShellHarness(
            arguments: ["Gita", "--repository", repository.url.path], isDevelopment: isDevelopment)
        await shell.launch(waitingFor: repository.url)
        return shell
    }

    private func repository() throws -> TemporaryRepository {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        return repository
    }

    // MARK: Setup guide

    @Test func aFirstLaunchShowsTheGuideAndAppliesOnlyItsChanges() async throws {
        let shell = AppShellHarness(arguments: ["Gita"], isDevelopment: false)
        await shell.launch()
        defer { shell.tearDown() }
        let guide = try #require(shell.recorder.guides.first)
        #expect(guide.presentedOn != nil)
        #expect(guide.request.firstRun)
        let menu = try #require(shell.menuItem(#selector(RepositoryCommandResponder.newBranch)))
        #expect(!shell.app.validateMenuItem(menu))
        shell.app.application(NSApp, open: [URL(fileURLWithPath: "/tmp")])
        #expect(shell.app.router.pending.count == 1)
        var choices = guide.request.choices
        choices.historyZoomPercent = 130
        choices[.showsHistoryDetails].toggle()
        choices[.providerRefresh] = false
        choices[.useVercel] = false
        guide.request.onFinish(choices)
        #expect(guide.dismissed)
        #expect(shell.app.setupGuide == nil)
        #expect(shell.defaults.integer(forKey: Preference.historyZoomPercent.rawValue) == 130)
        #expect(!Preference.useVercel.bool(shell.defaults) && !Preference.providerRefresh.bool(shell.defaults))
        #expect(Preference.useGitHub.bool(shell.defaults))
        #expect(shell.defaults.integer(forKey: SetupGuideState.defaultsKey) == SetupGuideState.version)
        await appWaitUntil { shell.app.router.pending.isEmpty }
    }

    @Test func theGuideFromTheMenuCanBeCancelledByClosingOrQuitting() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.showSetupGuide()
        #expect(shell.recorder.guides.count == 1)
        shell.app.showSetupGuide()
        #expect(shell.recorder.guides.count == 1)
        shell.app.closeWindow()
        #expect(shell.app.setupGuide == nil)
        shell.app.showSetupGuide()
        #expect(!shell.app.windows.shouldClose())
        shell.app.showSetupGuide()
        #expect(shell.app.applicationShouldTerminate(NSApp) == .terminateNow)
        shell.app.showSetupGuide()
        shell.recorder.guides.last?.request.onCancel()
        shell.app.showSetupGuide()
        shell.app.quit()
        await appWaitUntil { shell.recorder.terminations == 1 }
    }

    // MARK: Login offer

    @Test func acceptingTheLoginOfferReportsEachOutcome() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let offer = shell.app.loginOffer
        offer.canOffer = { true }
        let outcomes: [Result<LoginItem.Status, Error>] = [
            .success(.enabled), .success(.requiresApproval), .success(.unavailable),
            .failure(CocoaError(.fileNoSuchFile)),
        ]
        for outcome in outcomes {
            shell.recorder.loginResult = outcome
            offer.update()
            await appWaitUntil { offer.isShown }
            offer.onAccept()
            #expect(!offer.isShown)
        }
        #expect(shell.recorder.loginSettingsOpened == 1)
        #expect(shell.alerts.alerts.count == 2)
        offer.update()
        await appWaitUntil { offer.isShown }
        offer.onDismiss()
        #expect(Preference.loginItemOfferAnswered.bool(shell.defaults))
        offer.onAccept()
    }

    @Test func theOfferViewAnswersOnce() {
        UITestSupport.bootstrap()
        let answers = AppBox<[Bool]>([])
        let view = LoginOfferView(onAccept: { answers.value.append(true) }, onDismiss: { answers.value.append(false) })
        view.frame = NSRect(x: 0, y: 0, width: 330, height: 110)
        view.layoutSubtreeIfNeeded()
        view.viewDidChangeEffectiveAppearance()
        UITestSupport.render(view)
        #expect(view.intrinsicContentSize.width == 330)
        view.cancelOperation(nil)
        for button in AppRecordingAlerts.views(of: NSButton.self, in: view) { button.performClick(nil) }
        #expect(answers.value == [false])
        let accepting = LoginOfferView(onAccept: { answers.value.append(true) }, onDismiss: {})
        AppRecordingAlerts.views(of: NSButton.self, in: accepting).last?.performClick(nil)
        #expect(answers.value == [false, true])
    }

    // MARK: Closing and quitting

    @Test func closeTabClosesASheetFirst() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let window = try #require(shell.app.mainWindow)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        #expect(!shell.app.windows.shouldClose())
        window.endSheet(sheet)
        shell.app.closeWindow()
        await appWaitUntil { shell.app.mainWindow == nil }
        shell.app.closeWindow()
    }

    @Test func aRunningGitActionBlocksQuitting() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.model.isMutating = true
        #expect(shell.app.applicationShouldTerminate(NSApp) == .terminateCancel)
        shell.app.quit()
        #expect(shell.recorder.terminations == 0)
        #expect(shell.recorder.beeps == 2)
        shell.app.restartForLanguage()
        #expect(shell.recorder.beeps == 3)
        shell.app.selectPanelRepository(repository.url)
        shell.app.model.isMutating = false
    }

    // MARK: Recent repositories, pages and panels

    @Test func recentRepositoriesOpenFromTheirMenu() async throws {
        let repository = try repository()
        let other = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.defaults.set([other.url.path, repository.url.path], forKey: Preference.recentRepositories.rawValue)
        let menu = shell.app.recentMenu()
        #expect(menu.items.count == 2)
        let first = try #require(menu.items.first)
        shell.app.openRecentPath(first)
        await appWaitUntil { shell.app.tabsController?.count == 2 }
        #expect(shell.app.panelRepositoryURLs.count == 2)
    }

    @Test func pagesAndPanesFromTheViewMenu() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let item = NSMenuItem()
        item.representedObject = Section.changes.rawValue
        shell.app.navigate(item)
        #expect(shell.app.model.section == .changes)
        item.representedObject = Section.worktrees.rawValue
        shell.app.navigate(item)
        item.representedObject = "nothing"
        shell.app.navigate(item)
        shell.app.showAgentsPane()
        shell.app.toggleRepositorySidebar()
        shell.app.findInHistory()
        shell.app.openAuthorTab(CommitAuthor(try #require(shell.app.model.snapshot?.commits.first)), in: repository.url)
        await appWaitUntil { shell.app.tabsController?.count == 2 }
    }

    @Test func cloneAsksForTheRemoteAndTheFolder() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.cloneRepository()
        #expect(shell.alerts.fields.count == 2)
        #expect(shell.alerts.fields.last?.stringValue.hasSuffix("Projects/repository") == true)
        shell.alerts.answer(.alertSecondButtonReturn)
        shell.app.commands.createTagAt(try #require(shell.app.model.snapshot?.commits.first))
        shell.app.commands.pushBranch("main")
        await shell.settle()
    }

    @Test func theStandardAlertPresenterUsesTheGivenWindow() {
        UITestSupport.bootstrap()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let alert = NSAlert()
        AlertPresenter.standard.present(alert, on: window)
        #expect(window.attachedSheet != nil)
        window.attachedSheet.map { window.endSheet($0) }
    }
}
