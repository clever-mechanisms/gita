import AppKit
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor @Suite struct ControlPlanePresenterTests {
    @Test func ciLoadsEditsAndLaunchesWithChosenDestination() async throws {
        let target = try #require(
            CIFixTarget(
                root: URL(fileURLWithPath: "/tmp/example"),
                repositoryNameWithOwner: "org/example", runID: 5))
        let context = CIFixContext(
            target: target, branch: "main", commitSHA: nil, failedStepName: "test",
            logExcerpt: "failure", changedFiles: [], prompt: "First draft", wasLogTruncated: false)
        var delivered: String?
        let presenter = CIFixPresenter(
            target: target, agents: [.codex, .gemini], fetch: { context },
            launch: {
                agent, destination, prompt in
                #expect(agent == .gemini && destination == .external)
                delivered = prompt
            })
        var transitions: [CIFixState] = []
        presenter.changed = { [weak presenter] in if let state = presenter?.state { transitions.append(state) } }
        #expect(presenter.state == .idle)
        await presenter.load().value
        presenter.prompt = "Edited repair request"
        presenter.selectedAgent = .gemini
        presenter.destination = .external
        presenter.launch()
        #expect(transitions == [.loading, .ready(context), .launching(.gemini, context), .launched(.gemini)])
        #expect(delivered == "Edited repair request")
    }

    @Test func dismissCancelsPendingContext() async throws {
        let target = try #require(
            CIFixTarget(
                root: URL(fileURLWithPath: "/tmp/example"),
                repositoryNameWithOwner: "org/example", runID: 5))
        let presenter = CIFixPresenter(
            target: target, agents: [],
            fetch: {
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }, launch: { _, _, _ in Issue.record("Unexpected launch") })
        let task = presenter.load()
        presenter.cancel()
        await task.value
        #expect(presenter.state == .idle)
    }

    @Test func workspacePersistsTabFiltersTimelineAndExecutesReviewedPlan() async throws {
        let repo = try TemporaryRepository()
        try repo.commit("file", "text", message: "First")
        let repository = WorkspaceRepository(root: repo.url)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = ProviderItem(
            id: "pr", provider: .github, category: "", title: "Review", state: .success, date: Date(),
            kind: .pullRequest, pullRequest: .init(number: 1, lifecycle: .open, isDraft: false))
        let report = ProviderReport(provider: .github, items: [item], status: .connected)
        let presenter = WorkspaceCommandCenterPresenter(
            repositories: [repository], reports: [repo.url: [report]], defaults: defaults
        ) { _ in }
        presenter.select(.timeline)
        await presenter.refresh()?.value
        #expect(presenter.filteredEvents.count == 2)
        presenter.setFilter(.pullRequests)
        #expect(presenter.filteredEvents.map(\.title) == ["Review"])
        presenter.setFilter(.deployments)
        #expect(presenter.filteredEvents.isEmpty)
        presenter.select(.lockstep)
        presenter.edit(branch: "ship", mode: .createOnly)
        presenter.toggle(repository)
        #expect(presenter.preflight() == nil)
        presenter.toggle(repository)
        await presenter.preflight()?.value
        guard case .reviewed(let plan) = presenter.lockstep else {
            Issue.record("Expected reviewed plan")
            return
        }
        #expect(plan.entries.first?.safety == .ready)
        await presenter.execute(allowWarnings: false)?.value
        #expect(try repo.git("branch", "--show-current") == "ship\n")
        let restored = WorkspaceCommandCenterPresenter(repositories: [], reports: [:], defaults: defaults) { _ in }
        #expect(restored.tab == .lockstep)
    }

    @Test func sheetsAndCommandCenterLayOutWithNativeKeyboardActions() throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let target = try #require(CIFixTarget(root: repo.url, repositoryNameWithOwner: "dev/example", runID: 1))
        let ci = CIFixSheetController(
            presenter: CIFixPresenter(
                target: target, agents: [],
                fetch: {
                    throw CancellationError()
                }, launch: { _, _, _ in }))
        ci.chrome.window.layoutIfNeeded()
        #expect(ci.chrome.footer.arrangedSubviews.last === ci.primary)
        #expect(ci.primary.keyEquivalent == "\r" && ci.closeButton.keyEquivalent == "\u{1b}")
        #expect(ci.chrome.window.contentView is ThemedBackgroundView)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = WorkspaceCommandCenterPresenter(repositories: [], reports: [:], defaults: defaults) { _ in }
        let controller = WorkspaceCommandCenterWindowController(title: "Workspace", presenter: workspace)
        for tab in [WorkspaceCommandCenterPresenter.Tab.changes, .lockstep, .timeline] {
            workspace.select(tab)
            controller.window?.layoutIfNeeded()
        }
        #expect(controller.window?.isReleasedWhenClosed == false)
        #expect(controller.windowFrameAutosaveName == "GitaWorkspaceCommandCenter")
    }

    @Test func facadeConvertsWorkspaceTabsAndGroupColors() throws {
        let repo = try TemporaryRepository()
        let group = TabGroup(id: UUID(), name: "Clients", color: .purple)
        let session = RepositoryTabSession(repositories: [repo.url], selected: repo.url, groups: [(group, [repo.url])])
        let repositories = ControlPlaneFacade.repositories(
            for: Workspace(id: "clients", name: "Client apps"), session: session)
        #expect(repositories.count == 1)
        let first = try #require(repositories.first)
        #expect(first.root == repo.url.standardizedFileURL.resolvingSymlinksInPath())
        #expect(first.groupName == "Clients" && first.tabColorRawValue == "purple")
    }
}

extension ControlPlanePresenterTests {
    private func workspace(
        _ repos: [WorkspaceRepository], open: @escaping @MainActor (URL) -> Void = { _ in }
    )
        -> WorkspaceCommandCenterPresenter
    {
        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        return WorkspaceCommandCenterPresenter(repositories: repos, reports: [:], defaults: defaults, open: open)
    }

    @Test func conflictBlocksRowButtonMenuAndPresenter() async throws {
        UITestSupport.bootstrap()
        let git = try TemporaryRepository()
        try git.commit("file", "base", message: "Base")
        try git.git("switch", "-c", "other")
        try git.commit("file", "other", message: "Other")
        try git.git("switch", "main")
        try git.commit("file", "main", message: "Main")
        #expect(throws: TemporaryRepository.GitFailure.self) { try git.git("merge", "other") }
        try git.write("untracked", "new")
        let repo = WorkspaceRepository(root: git.url)
        var opened: [URL] = []
        let presenter = workspace([repo]) { opened.append($0) }
        await presenter.refresh()?.value
        let changes = WorkspaceChangesTabView(presenter)
        let window = SharedEvents.window(containing: changes)
        changes.render()
        window.layoutIfNeeded()
        let table = try SheetsSupport.require("controlPlane.workspace.changes.table", in: window, as: NSTableView.self)
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let stage: PartsButton = try #require(SheetsSupport.view("controlPlane.workspace.changes.stage", in: cell))
        #expect(!stage.isEnabled && stage.toolTip == String(localized: "Resolve conflicts first"))
        let labels = SheetsSupport.views(in: cell, of: NSTextField.self).map(\.stringValue)
        #expect(labels.contains(String(localized: "1 untracked · 1 conflict")))
        let rect = table.rect(ofRow: 0)
        let mouse = try #require(
            SharedEvents.mouse(.rightMouseDown, at: NSPoint(x: rect.midX, y: rect.midY), in: table))
        let menu = try #require(table.menu(for: mouse))
        #expect(menu.items.map(\.title) == [String(localized: "Open Repository"), String(localized: "Stage All")])
        #expect(menu.items.last?.isEnabled == false)
        menu.performActionForItem(at: 0)
        table.keyDown(with: try #require(SharedEvents.key("\r", code: KeyPress.returnKey)))
        #expect(opened == [repo.root, repo.root])
        #expect(presenter.stage(repo) == nil)
        #expect(try !git.git("ls-files", "-u").isEmpty)
    }

    @Test func stageFailureAndRetryStayOnTheAffectedRow() async throws {
        UITestSupport.bootstrap()
        let a = try TemporaryRepository()
        let b = try TemporaryRepository()
        try a.write("one", "a")
        try b.write("two", "b")
        let first = WorkspaceRepository(root: a.url)
        let second = WorkspaceRepository(root: b.url)
        let presenter = workspace([first, second])
        await presenter.refresh()?.value
        let view = WorkspaceChangesTabView(presenter)
        let window = SharedEvents.window(containing: view)
        presenter.changed = { [weak view] in view?.render() }
        view.render()
        window.layoutIfNeeded()
        let table = try SheetsSupport.require("controlPlane.workspace.changes.table", in: window, as: NSTableView.self)
        let before = presenter.changes
        let lock = a.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        let failure = try #require(presenter.stage(first))
        #expect(presenter.stagingRepositories == [first.id] && presenter.changes == before)
        #expect(presenter.stage(first) == nil)
        let stageID = "controlPlane.workspace.changes.stage"
        let button: PartsButton = try #require(
            SheetsSupport.view(stageID, in: table.view(atColumn: 0, row: 0, makeIfNecessary: true)))
        #expect(!button.isEnabled && button.accessibilityLabel() == String(localized: "Staging…"))
        let success = try #require(presenter.stage(second))
        await failure.value
        await success.value
        guard case .loaded(let rows) = presenter.changes else {
            Issue.record("Staging must keep the workspace visible")
            return
        }
        #expect(rows.map(\.untrackedCount) == [1, 0] && rows.map(\.stagedCount) == [0, 1])
        #expect(presenter.stagingRepositories.isEmpty && Array(presenter.stageErrors.keys) == [first.id])
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let details = SheetsSupport.views(in: cell, of: NSTextField.self)
        #expect(details.contains { $0.stringValue == presenter.stageErrors[first.id] && $0.textColor == Theme.failure })
        try FileManager.default.removeItem(at: lock)
        await presenter.stage(first)?.value
        #expect(presenter.stageErrors.isEmpty)
        guard case .loaded(let updated) = presenter.changes else {
            Issue.record("Expected staged rows")
            return
        }
        #expect(updated.map(\.stagedCount) == [1, 1])
    }

    @Test func tabSwitchPublishesOnlyLoadingAndCloseCancelsAllReads() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let presenter = workspace([WorkspaceRepository(root: repo.url)])
        let controller = WorkspaceCommandCenterWindowController(title: "Testing", presenter: presenter)
        let window = try #require(controller.window)
        controller.showWindow(nil)
        presenter.cancelAll()
        var loading: [Bool] = []
        presenter.changed = {
            loading.append(presenter.tab == .changes ? presenter.changes == .loading : presenter.timeline == .loading)
        }
        let one = try #require(SharedEvents.key("1", code: 18, modifiers: [.command, .control]))
        let two = try #require(SharedEvents.key("2", code: 19, modifiers: [.command, .control]))
        let three = try #require(SharedEvents.key("3", code: 20, modifiers: [.command, .control]))
        let refresh = try #require(SharedEvents.key("r", code: 15, modifiers: .command))
        #expect(window.performKeyEquivalent(with: one))
        #expect(loading == [true])
        let changes = try #require(presenter.refresh())
        #expect(window.performKeyEquivalent(with: three))
        #expect(presenter.tab == .timeline && loading == [true, true, true])
        #expect(window.performKeyEquivalent(with: refresh))
        let timeline = try #require(presenter.refresh())
        #expect(window.performKeyEquivalent(with: two))
        #expect(presenter.tab == .lockstep)
        presenter.edit(branch: "feature", mode: .createOnly)
        let plan = try #require(presenter.preflight())
        presenter.changed = nil
        window.close()
        for task in [changes, timeline, plan] {
            #expect(task.isCancelled)
            await task.value
        }
        #expect(presenter.changes == .idle && presenter.timeline == .idle && presenter.lockstep == .idle)
    }

    @Test func facadeReusesWindowAndReplacesWorkspaceInputs() async throws {
        UITestSupport.bootstrap()
        let git = try TemporaryRepository()
        let repo = WorkspaceRepository(root: git.url)
        let facade = ControlPlaneFacade()
        let first = facade.showWorkspaceCommandCenter(workspaceTitle: "First", repositories: [], providerReports: [:]) {
            _ in Issue.record("Old callback")
        }
        let controller = try #require(first as? WorkspaceCommandCenterWindowController)
        let originalTab = controller.presenter.tab
        defer {
            controller.presenter.select(originalTab)
            controller.close()
        }
        controller.presenter.select(.timeline)
        var opened: URL?
        let item = ProviderItem(
            id: "pr", provider: .github, category: "", title: "New review", state: .success, date: Date(),
            kind: .pullRequest, pullRequest: .init(number: 2, lifecycle: .open, isDraft: false))
        let report = ProviderReport(provider: .github, items: [item], status: .connected)
        let second = facade.showWorkspaceCommandCenter(
            workspaceTitle: "Second", repositories: [repo], providerReports: [repo.root: [report]]
        ) { opened = $0 }
        #expect(first === second && second.window?.subtitle == "Second")
        #expect(second.window?.toolbar != nil && controller.presenter.selected == [repo.id])
        #expect(controller.presenter.repositories == [repo])
        controller.presenter.open(repo.root)
        #expect(opened == repo.root)
        try await SheetsSupport.wait { controller.presenter.timeline != .loading }
        #expect(controller.presenter.filteredEvents.map(\.title) == ["New review"])
    }

    @Test func ciRetryRestoresDefaultTitleWithNoAgent() async throws {
        UITestSupport.bootstrap()
        let target = try #require(
            CIFixTarget(root: URL(fileURLWithPath: "/tmp/example"), repositoryNameWithOwner: "org/example", runID: 5))
        actor Fetch {
            var attempted = false
            func load(_ target: CIFixTarget) throws -> CIFixContext {
                defer { attempted = true }
                guard attempted else { throw SheetsFailure() }
                return CIFixContext(
                    target: target, branch: "main", commitSHA: nil, failedStepName: nil, logExcerpt: "",
                    changedFiles: [], prompt: "Review failure", wasLogTruncated: false)
            }
        }
        let fetch = Fetch()
        let presenter = CIFixPresenter(
            target: target, agents: [], fetch: { try await fetch.load(target) }, launch: { _, _, _ in })
        let sheet = CIFixSheetController(presenter: presenter)
        await presenter.load().value
        #expect(sheet.primary.title == String(localized: "Retry"))
        sheet.performPrimary()
        #expect(presenter.state == .loading)
        #expect(sheet.primary.title == String(localized: "Fix with Agent") && !sheet.primary.isEnabled)
        try await SheetsSupport.wait { presenter.state != .loading }
        guard case .ready = presenter.state else {
            Issue.record("Retry should restore the ready state")
            return
        }
        #expect(sheet.primary.title == String(localized: "Fix with Agent") && !sheet.primary.isEnabled)
    }

    @Test func lockstepTypingKeepsRowsAndReturnReviewsThePlan() async throws {
        UITestSupport.bootstrap()
        let git = try TemporaryRepository()
        let presenter = workspace([WorkspaceRepository(root: git.url)])
        let view = WorkspaceLockstepTabView(presenter)
        let window = SharedEvents.window(containing: view)
        presenter.changed = { [weak view] in view?.render() }
        view.render()
        window.layoutIfNeeded()
        let branch: NSTextField = try SheetsSupport.require("controlPlane.workspace.lockstep.branch", in: window)
        let table: NSTableView = try SheetsSupport.require("controlPlane.workspace.lockstep.table", in: window)
        let action: PartsButton = try SheetsSupport.require("controlPlane.workspace.lockstep.run", in: window)
        let firstCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let first = try #require(firstCell.subviews.first)
        #expect(!action.isEnabled && action.background == .accent)
        SheetsSupport.type("feature", into: branch)
        #expect(action.isEnabled)
        let updatedCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(updatedCell.subviews.first === first)
        branch.sendAction(branch.action, to: branch.target)
        #expect(presenter.lockstep == .checking && !action.isEnabled)
        try await SheetsSupport.wait { presenter.lockstep != .checking }
        #expect(action.accessibilityLabel() == String(localized: "Run Lockstep"))
    }

    @Test func closingCommandCenterPreservesExecutingLockstepRun() async throws {
        UITestSupport.bootstrap()
        let git = try TemporaryRepository()
        try git.commit("file", "base", message: "Base")
        let repo = WorkspaceRepository(root: git.url)
        let presenter = workspace([repo])
        let controller = WorkspaceCommandCenterWindowController(title: "Work", presenter: presenter)
        let window = try #require(controller.window)
        let tabTwo = try #require(SharedEvents.key("2", code: 19, modifiers: [.command, .control]))
        #expect(window.performKeyEquivalent(with: tabTwo))
        #expect(presenter.tab == .lockstep)
        presenter.edit(branch: "lockstep-keep", mode: .createOrCheckout)
        await presenter.preflight()?.value
        let execution = try #require(presenter.execute(allowWarnings: false))
        #expect(presenter.lockstep == .executing)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(presenter.lockstep == .executing)
        await execution.value
        guard case .completed(let outcomes) = presenter.lockstep else {
            Issue.record("Lockstep outcomes should survive window close while executing")
            return
        }
        #expect(outcomes.count == 1 && outcomes[0].status == .succeeded)
    }
}
