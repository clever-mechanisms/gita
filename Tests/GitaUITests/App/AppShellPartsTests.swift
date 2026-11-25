import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("App launch plan")
struct AppLaunchPlanTests {
    private func inputs(
        background: Bool = false, pending: [URL] = [],
        saved: RepositoryTabSession? = nil,
        stored: Bool = false, recent: [String] = [], guide: Int? = nil
    ) -> LaunchPlan.Inputs {
        LaunchPlan.Inputs(
            arguments: ["Gita"], isDevelopment: false, background: background, pendingURLs: pending,
            commandLineRepository: nil, saved: saved, hasStoredSession: stored, recent: recent,
            storedGuideVersion: guide)
    }

    @Test func aFirstInteractiveLaunchShowsTheGuide() {
        let plan = LaunchPlan(inputs())
        #expect(plan.initialSetupPending)
        #expect(!plan.marksGuideSeen)
        #expect(plan.session.repositories.isEmpty)
    }

    @Test func anUpdateForSomeoneUsingRepositoriesCountsTheGuideAsSeen() {
        let plan = LaunchPlan(inputs(recent: ["/tmp/one"]))
        #expect(plan.marksGuideSeen)
        #expect(!plan.initialSetupPending)
        #expect(plan.session.selectedRepository?.lastPathComponent == "one")
    }

    @Test func backgroundLaunchesRequestsAndArgumentsSkipTheGuide() {
        #expect(!LaunchPlan(inputs(background: true)).initialSetupPending)
        var scripted = inputs()
        scripted.arguments.append("--x")
        #expect(!LaunchPlan(scripted).initialSetupPending)
        let plan = LaunchPlan(inputs(pending: [URL(fileURLWithPath: "/tmp/two")], guide: SetupGuideState.version))
        #expect(!plan.initialSetupPending)
        #expect(plan.session.repositories.map(\.lastPathComponent) == ["two"])
    }

    @Test func aSavedSessionIsKeptAndTheRequestedRepositoryFocused() {
        var inputs = inputs(saved: RepositoryTabSession(), stored: true, recent: ["/tmp/recent"])
        inputs.commandLineRepository = URL(fileURLWithPath: "/tmp/asked")
        let plan = LaunchPlan(inputs)
        #expect(plan.session.repositories.map(\.lastPathComponent) == ["asked"])
    }
}

@Suite("App URL router")
@MainActor
struct AppURLRouterTests {
    @Test func routesFoldersPagesAndOtherLinks() throws {
        let router = URLRouter(scheme: "gita")
        #expect(router.route(URL(fileURLWithPath: "/tmp")) == .repository(URL(fileURLWithPath: "/tmp")))
        #expect(router.route(try #require(URL(string: "gita://open/history"))) == .window(.history))
        #expect(router.route(try #require(URL(string: "gita://pull-requests"))) == .window(.pullRequests))
        #expect(router.route(try #require(URL(string: "gita://open"))) == .window(nil))
        #expect(router.route(try #require(URL(string: "https://example.invalid"))) == .ignored)
    }

    @Test func pendingRequestsDrainOnce() {
        let router = URLRouter(scheme: "gita")
        router.enqueue([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        #expect(router.drain().count == 2)
        #expect(router.drain().isEmpty)
    }
}

@Suite("App shell gate and termination")
struct AppShellGateTests {
    @Test func restartingNeedsAQuietMainWindow() {
        var gate = ShellGate(hasMainWindow: true)
        #expect(gate.canRestartForLanguage)
        #expect(gate.canPresentSetupGuide)
        gate.hasReviewSheet = true
        #expect(!gate.canRestartForLanguage)
        gate = ShellGate(hasMainWindow: true, isAttentionInFlight: true)
        #expect(!gate.canRestartForLanguage)
    }

    @Test func theLoginOfferWaitsForASettledRepositoryWindow() {
        var gate = ShellGate(hasSnapshot: true, isWindowInFront: true, hasSeenSetupGuide: true)
        #expect(gate.canOfferLogin)
        gate.isLoading = true
        #expect(!gate.canOfferLogin)
        gate = ShellGate(hasSnapshot: true, launchedInBackground: true, isWindowInFront: true, hasSeenSetupGuide: true)
        #expect(!gate.canOfferLogin)
    }

    @Test(arguments: [
        (false, false, TerminationPolicy.now), (false, true, .refuseWhileMutating), (true, true, .askReviewSheet),
    ])
    func termination(hasReviewSheet: Bool, isMutating: Bool, expected: TerminationPolicy) {
        #expect(TerminationPolicy(hasReviewSheet: hasReviewSheet, isMutating: isMutating) == expected)
    }
}

@Suite("App single instance")
@MainActor
struct AppSingleInstanceTests {
    @Test func handsOverOnlyToAnEarlierLaunch() {
        let now = Date()
        let current = SingleInstance.Instance(processIdentifier: 20, launchDate: now)
        let earlier = SingleInstance.Instance(processIdentifier: 30, launchDate: now.addingTimeInterval(-5))
        let later = SingleInstance.Instance(processIdentifier: 10, launchDate: now.addingTimeInterval(5))
        #expect(SingleInstance.handOverTarget(current, others: [later, earlier]) == earlier)
        #expect(SingleInstance.handOverTarget(current, others: [later]) == nil)
        #expect(SingleInstance.handOverTarget(current, others: []) == nil)
        let tie = SingleInstance.Instance(processIdentifier: 5, launchDate: now)
        #expect(SingleInstance.handOverTarget(current, others: [tie]) == tie)
        #expect(SingleInstance.earlierInstance(bundleIdentifier: "dev.invalid.GitaUITests.\(UUID())") == nil)
    }

    @Test func takesOnlyAbsolutePathsOfExistingFolders() throws {
        let folder = FileManager.default.temporaryDirectory.path
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-\(UUID()).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let folders = SingleInstance.repositoryFolders([folder, "relative", file.path, "/nonexistent-\(UUID())"])
        #expect(folders.count == 1)
        #expect(SingleInstance.repositoryFolders(42).isEmpty)
    }
}

@Suite("App small parts")
@MainActor
struct AppSmallPartsTests {
    @Test func typedPathsExpandTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(TypedPath.expandingTilde("~") == home)
        #expect(TypedPath.expandingTilde("~/Projects") == home + "/Projects")
        #expect(TypedPath.expandingTilde("/tmp/x") == "/tmp/x")
        #expect(TypedPath.expandingTilde("~nobody-\(UUID().uuidString)/x").hasPrefix("~"))
        #expect(TypedPath.url("/tmp/x").path == "/tmp/x")
    }

    @Test func theReferencePickerSkipsTheCurrentBranchAndResolvesTypedText() {
        let refs = [
            GitReference(name: "work", fullName: "refs/heads/work", commit: "a", kind: .branch, isCurrent: true),
            GitReference(name: "main", fullName: "refs/heads/main", commit: "b", kind: .branch),
            GitReference(name: "origin/x", fullName: "refs/remotes/origin/x", commit: "c", kind: .remote),
        ]
        let pick = ReferencePick(references: refs)
        #expect(pick.names == ["main", "origin/x"])
        #expect(pick.initialIndex(preselect: "refs/remotes/origin/x") == 1)
        #expect(pick.initialIndex(preselect: nil) == 0)
        #expect(pick.resolve(selectedIndex: 0, text: "main") == "refs/heads/main")
        #expect(pick.resolve(selectedIndex: 0, text: "abc123") == "abc123")
        #expect(pick.resolve(selectedIndex: -1, text: "HEAD~1") == "HEAD~1")
    }

    @Test func windowContentOpensOnlyInALaunchedOpenShell() {
        #expect(ShellGate().canOpenWindowContent)
        #expect(!ShellGate(isLaunched: false).canOpenWindowContent)
        #expect(!ShellGate(isLanguageRestarting: true).canOpenWindowContent)
        #expect(!ShellGate(hasSetupGuide: true).canOpenWindowContent)
    }

    @Test func theLaunchPhaseKeepsAWindowAskedForBeforeLaunch() {
        var phase = LaunchPhase.starting(wantsWindow: false)
        #expect(!phase.isLaunched)
        #expect(!phase.wantsWindow)
        phase.requestWindow()
        #expect(phase.wantsWindow)
        let task = Task<Void, Never> {}
        phase = .waitingForPredecessor(task, wantsWindow: phase.wantsWindow)
        #expect(phase.wantsWindow)
        phase = .waitingForPredecessor(task, wantsWindow: false)
        phase.requestWindow()
        #expect(phase.wantsWindow)
        phase.cancel()
        #expect(task.isCancelled)
        phase = .launched
        phase.requestWindow()
        #expect(phase.isLaunched)
        #expect(!phase.wantsWindow)
    }

    @Test func aPanelPushRunsOnceItsRepositoryIsReadyOrExpires() {
        var queue = PanelPushQueue()
        let url = URL(fileURLWithPath: "/tmp/repo")
        let start = Date()
        let push1 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(!push1)
        queue.request(url, at: start)
        let push2 = queue.shouldPush(activeRoot: url, isBusy: true, now: start)
        #expect(!push2)
        let push3 = queue.shouldPush(activeRoot: URL(fileURLWithPath: "/tmp/other"), isBusy: false, now: start)
        #expect(!push3)
        let push4 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(push4)
        let push5 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(!push5)
        queue.request(url, at: start)
        let push6 = queue.shouldPush(
            activeRoot: url, isBusy: false, now: start.addingTimeInterval(PanelPushQueue.lifetime + 1))
        #expect(!push6)
        let push7 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(!push7)
    }

    @Test func aPanelPushIsDroppedWhenAnotherRepositoryTakesOver() {
        var queue = PanelPushQueue()
        let url = URL(fileURLWithPath: "/tmp/repo")
        let other = URL(fileURLWithPath: "/tmp/other")
        let start = Date()
        // Its tab opened and failed: the active tab shows no repository once it settles.
        queue.request(url, at: start)
        queue.activeRepositoryChanged()
        let push1 = queue.shouldPush(activeRoot: nil, isBusy: true, now: start)
        #expect(!push1)
        #expect(queue.request == .selected(url, at: start))
        let push2 = queue.shouldPush(activeRoot: nil, isBusy: false, now: start)
        #expect(!push2)
        #expect(queue.request == .none)
        // Choosing that repository again later does not push.
        let push3 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(!push3)
        // Another repository was chosen while it opened in the background.
        queue.request(url, at: start)
        queue.activeRepositoryChanged()
        let push4 = queue.shouldPush(activeRoot: other, isBusy: false, now: start)
        #expect(!push4)
        #expect(queue.request == .none)
        // A second change of the active repository is the user moving on.
        queue.request(url, at: start)
        queue.activeRepositoryChanged()
        queue.activeRepositoryChanged()
        #expect(queue.request == .none)
        // The selected repository settles: it pushes.
        queue.request(url, at: start)
        queue.activeRepositoryChanged()
        let push5 = queue.shouldPush(activeRoot: url, isBusy: false, now: start)
        #expect(push5)
        queue.activeRepositoryChanged()
        #expect(queue.request == .none)
    }

    @Test func theStatusItemShowsAgentsAndWhatNeedsYou() {
        func item(_ kind: PanelAttention.Item.Kind) -> PanelAttention.Item {
            .init(id: "\(kind)", kind: kind, repository: URL(fileURLWithPath: "/r/app"), detail: "app")
        }
        var agents = AgentSummary()
        let quiet = StatusItemLook(agents: agents, attention: [], showsCount: true, showsDot: true)
        #expect(quiet.icon == MenuIcon.Look(count: nil, dot: false))
        #expect(quiet.toolTip == "Gitā")
        agents.working = 2
        let waiting = item(.agentWaiting(tool: .codex, session: "n"))
        let busy = StatusItemLook(
            agents: agents, attention: [waiting, item(.conflicts), item(.checksFailed)], showsCount: true,
            showsDot: true)
        #expect(busy.icon == MenuIcon.Look(count: 2, dot: true))
        #expect(busy.toolTip == "Gitā, 2 agents working, 1 needs input, Conflicts")
        // A requested review lights the dot by itself.
        let review = StatusItemLook(
            agents: AgentSummary(), attention: [item(.reviewRequested)], showsCount: true, showsDot: true)
        #expect(review.icon == MenuIcon.Look(count: nil, dot: true))
        #expect(review.toolTip == "Gitā, 1 to review")
        let hidden = StatusItemLook(
            agents: agents, attention: [item(.checksFailed)], showsCount: false, showsDot: false)
        #expect(hidden.icon == MenuIcon.Look(count: nil, dot: false))
        #expect(hidden.toolTip.hasSuffix(String(localized: "Checks failing")))
    }

    @Test func theMenuIconIsDrawnAndCachedPerLook() throws {
        for look in [MenuIcon.Look(count: nil, dot: false), .init(count: 12, dot: false), .init(count: 3, dot: true)] {
            let image = MenuIcon.image(for: look)
            #expect(image === MenuIcon.image(for: look))
            #expect(image.isTemplate == !look.dot)
            #expect(image.size.height == MenuIcon.height)
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        #expect(MenuIcon.width(for: .init(count: nil, dot: false), textWidth: 10) == 18)
        #expect(MenuIcon.width(for: .init(count: 1, dot: true), textWidth: 10) > 30)
    }

    @Test func aWindowFrameIsFittedOnItsScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let fitted = WindowFrameClamp.clamped(NSRect(x: 900, y: -50, width: 1_200, height: 600), in: visible)
        #expect(fitted == NSRect(x: 0, y: 0, width: 1_000, height: 600))
        let inside = NSRect(x: 10, y: 10, width: 100, height: 100)
        #expect(WindowFrameClamp.clamped(inside, in: visible) == inside)
    }

    @Test func theActivationPolicyFollowsTheTitledWindows() {
        UITestSupport.bootstrap()
        let policies = AppBox<[NSApplication.ActivationPolicy]>([])
        let activations = AppBox(0)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let closing = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        closing.isReleasedWhenClosed = false
        let windows = AppBox([closing])
        let coordinator = ActivationPolicyCoordinator(
            setPolicy: { policies.value.append($0) }, activate: { activations.value += 1 }, windows: { windows.value })
        coordinator.windowWillShow()
        #expect(policies.value == [.regular])
        #expect(activations.value == 1)
        coordinator.windowWillClose(closing)
        #expect(policies.value.last == .accessory)
        windows.value.append(other)
        #expect(!ActivationPolicyCoordinator.keepsRegular(windows.value, closing: closing))
    }

    @Test func alertsGoThroughThePresenter() {
        let shown = AppBox<[String]>([])
        let answer = AppBox(NSApplication.ModalResponse.alertFirstButtonReturn)
        let presenter = AlertPresenter { alert, _, completion in
            shown.value.append(alert.messageText)
            completion(answer.value)
        }
        let confirmed = AppBox(0)
        presenter.confirm(NSAlert()) { confirmed.value += 1 }
        answer.value = .alertSecondButtonReturn
        presenter.confirm(NSAlert()) { confirmed.value += 1 }
        presenter.showError("Title", String(repeating: "x", count: 3_000))
        #expect(confirmed.value == 1)
        #expect(shown.value.last == "Title")
    }

    @Test func placeholderStatusesNameRepositoriesUntilTheMonitorReports() {
        let urls = [URL(fileURLWithPath: "/a/app"), URL(fileURLWithPath: "/b/app"), URL(fileURLWithPath: "/c/web")]
        let statuses = MenuPanelStateBuilder.placeholders(urls)
        #expect(statuses.map(\.name).last == "web")
        #expect(Set(statuses.prefix(2).map(\.name)).count == 2)
        // Only the repositories in a workspace's tabs are shown; the closed workspace is listed after the front one.
        let workspaces: [MenuPanelState.Workspace] = [
            .init(id: "b", title: "Client", presence: .closed, repositories: ["/c/web"]),
            .init(id: "a", title: "Default", presence: .front, repositories: ["/a/app", "/missing"]),
        ]
        let builder = MenuPanelStateBuilder(activity: ProviderActivity(), agents: .shared)
        var shell = MenuPanelStateBuilder.Shell(statuses: statuses, workspaces: workspaces, isRefreshing: true)
        let state = builder.build(shell)
        #expect(state.repositories.map(\.id) == ["/a/app", "/c/web"])
        #expect(state.workspaces.map(\.id) == ["a", "b"])
        #expect(state.names.count == 3)
        #expect(state.isRefreshing)
        #expect(!state.attention.contains { $0.kind == .conflicts })
        // Conflicts in the active repository wait for the user, for the panel and for the icon alike.
        shell.snapshot = MenuBarFixtures.snapshot(urls[0])
        shell.hasConflicts = true
        #expect(builder.build(shell).attention.first?.kind == .conflicts)
        #expect(builder.attention(shell) == builder.build(shell).attention)
        shell.hasConflicts = false
        #expect(!builder.attention(shell).contains { $0.kind == .conflicts })
    }

    @Test func aResultsDestinationBecomesItsItem() throws {
        let destination = ProviderNotificationDestination(
            schemaVersion: 1, repositoryPath: "/tmp/repo", commonGitDirectoryPath: "/tmp/repo/.git",
            providerSourceID: "github:x", itemID: "7", target: .pullRequest(repository: "example/repo", number: 7),
            title: "PR", state: .success,
            branch: "main", commit: nil, url: nil, observedAt: Date())
        let request = AttentionRequest(destination)
        #expect(request.item.provider == .github)
        #expect(request.item.kind == .pullRequest)
        #expect(request.sourceID == "github:x")
        #expect(AttentionRequest.sameLocation(URL(fileURLWithPath: "/tmp/repo/"), request.repository))
    }
}
