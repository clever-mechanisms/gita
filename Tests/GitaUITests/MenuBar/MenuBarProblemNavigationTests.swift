import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarProblemNavigationTests {
    typealias MF = MenuBarFixtures

    private final class MockCommandHost: RepositoryCommandHost {
        var environment: AppEnvironment { .current }
        var mainWindow: NSWindow? { nil }
        var repositoryController: RepositoryViewController? { nil }
        func showWindow() {}
        func showPalette(scope _: PaletteKind?) {}
        func prompt(
            _: String, labels _: [String], defaults _: [String], button _: String,
            action _: @escaping @MainActor ([String]) -> Void
        ) {}
        func validateMenuItem(_: NSMenuItem) -> Bool { false }
        func openRepositoryTab(_: URL) {}
        func openAuthorTab(_: CommitAuthor, in _: URL) {}
        func removeFromRepositoryList(_: [String]) {}
    }

    private final class MockStatusItemHost: StatusItemHost {
        var model: AppModel
        var canChangeRepository = true
        var panelRepositoryURLs: [URL] = []
        var panelWorkspaces: [MenuPanelState.Workspace] = []
        var openedRepositories: [URL] = []
        var panelActions: MenuPanelActions {
            MenuPanelActions(showRepository: { [weak self] url in
                self?.openedRepositories.append(url)
                return self?.canChangeRepository == true
            })
        }
        let commandHost = MockCommandHost()
        lazy var commands = RepositoryCommandResponder(model: model, host: commandHost)

        init(model: AppModel) { self.model = model }
        func selectPanelRepository(_: URL) {}
        func panelVisibilityChanged() {}
    }

    private func findView(in root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = findView(in: child, identifier: identifier) { return found }
        }
        return nil
    }

    @Test func problemBandShowsFullTooltipAndClicksOpenProviderPage() throws {
        var openedPages: [(URL, ProviderKind)] = []
        let actions = MenuPanelActions(showProviderPage: { url, provider in
            openedPages.append((url, provider))
        })
        let controller = MenuPanelController(actions: actions)
        let window = UITestSupport.host(controller, size: NSSize(width: Theme.panelWidth, height: 400))

        let fullReason = "None of your GitHub accounts (rolottr) can see SQLI-International/monorepo."
        let state = MenuPanelState(
            problem: "GitHub · No access · monorepo",
            problemDetail: .init(
                text: "GitHub · No access · monorepo", toolTip: fullReason,
                repository: MF.repository, provider: .github))
        controller.update(state)
        controller.view.layoutSubtreeIfNeeded()

        let problemView = try #require(findView(in: controller.view, identifier: "panel.problem.band"))
        #expect(controller.problemLabel.stringValue == "GitHub · No access · monorepo")
        #expect(controller.problemLabel.toolTip == fullReason)
        #expect(problemView.toolTip == fullReason)
        #expect(problemView.accessibilityRole() == .button)
        #expect(problemView.accessibilityPerformPress())
        #expect(openedPages.count == 1)
        #expect(openedPages.first?.0 == MF.repository)
        #expect(openedPages.first?.1 == .github)

        // Mouse click inside the problem band also fires the action.
        let bounds = problemView.bounds
        let center = problemView.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let down = MenuBarPanelControllerTests.mouse(.leftMouseDown, at: center, in: window)
        let up = MenuBarPanelControllerTests.mouse(.leftMouseUp, at: center, in: window)
        problemView.mouseDown(with: down)
        problemView.mouseUp(with: up)
        #expect(openedPages.count == 2)
    }

    @Test func statusItemControllerNavigatesActiveAndPendingModelsToProviderPage() {
        UITestSupport.bootstrap()
        let suite = "GitaUITests.StatusItem.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }

        let activeModel = AppModel(defaults: defaults)
        activeModel.root = MF.repository
        let host = MockStatusItemHost(model: activeModel)
        let controller = StatusItemController(statusItem: NSStatusItem(), host: host, defaults: defaults)

        // Immediate navigation when the failing repository is already the active model.
        controller.openProviderPage(MF.repository, provider: .github)
        #expect(host.openedRepositories == [MF.repository])
        #expect(activeModel.section == .pullRequests)

        // Deferred navigation when the target tab activates after openRepository finishes loading.
        let pendingModel = AppModel(defaults: defaults)
        pendingModel.root = MF.site
        controller.openProviderPage(MF.site, provider: .github)
        #expect(activeModel.section == .pullRequests)
        #expect(pendingModel.section == .history)
        controller.activeModelChanged(pendingModel)
        #expect(pendingModel.section == .pullRequests)
        host.canChangeRepository = false
        pendingModel.section = .history
        controller.openProviderPage(MF.site, provider: .vercel)
        controller.activeModelChanged(pendingModel)
        #expect(pendingModel.section == .history)
    }

    @Test func statusItemControllerObservesPendingUpdateAndClearsOnAttentionOrFinish() {
        UITestSupport.bootstrap()
        let suite = "GitaUITests.StatusItemUpdate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        Preference.registerDefaults(in: defaults)

        let activeModel = AppModel(defaults: defaults)
        let host = MockStatusItemHost(model: activeModel)
        let updater = AppUpdater(activateApp: {}, presentUnavailable: {})
        let statusBar = NSStatusBar()
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        let controller = StatusItemController(statusItem: item, host: host, defaults: defaults, updater: updater)
        _ = controller

        let initialLook = StatusItemLook(
            agents: AgentSummary(), attention: [], showsCount: true, showsDot: true, pendingUpdateVersion: nil)
        #expect(!initialLook.icon.dot)
        #expect(initialLook.toolTip == "Gitā")

        let pendingLook = StatusItemLook(
            agents: AgentSummary(), attention: [], showsCount: true, showsDot: true, pendingUpdateVersion: "0.2.3")
        #expect(pendingLook.icon.dot)
        #expect(pendingLook.toolTip == "Gitā, Version 0.2.3 is available")

        updater.handleScheduledUpdatePresentation(handledBySparkle: false, version: "0.2.3")
        #expect(item.button?.toolTip?.contains("Version 0.2.3 is available") == true)

        updater.clearPendingVersion()
        #expect(item.button?.toolTip?.contains("Version 0.2.3 is available") == false)

        updater.handleScheduledUpdatePresentation(handledBySparkle: false, version: "0.2.4")
        #expect(item.button?.toolTip?.contains("Version 0.2.4 is available") == true)
        updater.standardUserDriverWillFinishUpdateSession()
        #expect(updater.pendingVersion == nil)
        #expect(updater.availableVersion == nil)
        #expect(item.button?.toolTip?.contains("Version 0.2.4 is available") == false)
    }
}
