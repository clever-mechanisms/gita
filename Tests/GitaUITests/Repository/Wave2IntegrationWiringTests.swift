import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Wave 2 cross-builder integration wiring", .serialized)
struct Wave2IntegrationWiringTests {
    @Test func reviewDiffViewAppliesSyntaxTokensAlongsideWordHighlightsAndTabWidth() throws {
        UITestSupport.bootstrap()
        let defaults = try SetupSandbox().defaults
        DiffPreference.setTabWidth(2, in: defaults)

        let view = ReviewDiffView(frame: NSRect(x: 0, y: 0, width: 720, height: 320))
        view.defaults = defaults
        let patch = """
            @@ -1,2 +1,2 @@
            -func oldValue() -> Int { 1 }
            +func newValue() -> Int { 2 }
            """
        view.show(
            ReviewDiffView.Content(
                patch: patch, path: "Sources/Sample.swift", threads: [], pending: [], viewer: "octocat",
                canWrite: true, takesComments: true, inReview: false))

        #expect(view.syntaxTokens.count == view.lines.count)
        #expect(view.syntaxTokens.contains { $0.contains { $0.kind == .keyword } })
        #expect(view.wordHighlights.contains { !$0.isEmpty })
        let lineRow = try #require(view.rows.firstIndex { if case .line(1) = $0 { true } else { false } })
        let cell = try #require(view.tableView(view.table, viewFor: nil, row: lineRow) as? DiffCell)
        #expect(cell.tabWidth == 2)
        #expect(!cell.syntaxTokens.isEmpty)
        #expect(!cell.wordHighlights.isEmpty)
        UITestSupport.render(view)
    }

    @Test func binaryDiffAndBinaryBlobRenderBinaryDiffEmptyViewWithActions() async throws {
        let oldBytes = Data([0x00, 0x01, 0x02, 0x03])
        let newBytes = Data([0x00, 0xFF, 0xFE, 0x01, 0x02, 0x03])
        let fixture = try await RepositoryWindowFixture { repo in
            let target = repo.url.appendingPathComponent("assets/logo.bin")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try oldBytes.write(to: target)
            try repo.git("add", "assets/logo.bin")
            try repo.git("commit", "-q", "-m", "Add binary logo")
            try newBytes.write(to: target)
        }
        defer { fixture.close() }

        fixture.model.section = .changes
        try await fixture.wait("binary diff shown") {
            !fixture.controller.codePane.diffView.binaryEmptyView.isHidden
        }
        try await fixture.wait("binary sizes resolved") {
            let summary = fixture.controller.codePane.diffView.binaryEmptyView.summary
            return summary?.oldByteCount == 4 && summary?.newByteCount == 6
        }

        let emptyView = fixture.controller.codePane.diffView.binaryEmptyView
        let summary = try #require(emptyView.summary)
        #expect(summary.path == "assets/logo.bin")
        #expect(summary.fileURL?.lastPathComponent == "logo.bin")
        #expect(summary.canRevealOrOpen)

        var opened: URL?
        var revealed: URL?
        emptyView.onOpen = { opened = $0 }
        emptyView.onRevealInFinder = { revealed = $0 }
        let buttons = SetupTestSupport.views(PartsButton.self, in: emptyView)
        try #require(buttons.first { $0.accessibilityIdentifier() == "binaryDiff.open" }).onClick?()
        try #require(buttons.first { $0.accessibilityIdentifier() == "binaryDiff.reveal" }).onClick?()
        #expect(opened == summary.fileURL && revealed == summary.fileURL)

        // Binary blob metadata in File Tree mode also activates BinaryDiffEmptyView.
        let blobDiffView = DiffView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        blobDiffView.repositoryRoot = fixture.repository.url
        blobDiffView.update(
            String(localized: "Binary file · 6 bytes"), loading: false, blob: true, path: "assets/logo.bin",
            binaryBlobByteCount: 6)
        #expect(!blobDiffView.binaryEmptyView.isHidden)
        #expect(blobDiffView.binaryEmptyView.summary?.newByteCount == 6)
    }

    @Test func pullRequestWorkspaceHostsProviderPageAndAdaptsAcrossThresholds() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        if !fixture.controller.sidebarView.isHidden { fixture.controller.toggleSidebar() }
        fixture.window.setContentSize(NSSize(width: 1_240, height: 800))
        fixture.controller.view.layoutSubtreeIfNeeded()

        var item = ReviewTestRunner.item
        item.pullRequest = PullRequestSummary(
            number: 42, lifecycle: .open, isDraft: false, author: "octocat", status: nil)
        let target = try #require(item.target)
        let reviewController = PullRequestReviewController.review(
            item, root: fixture.repository.url, service: PullRequestReviewService(runner: ReviewTestRunner()))
        #expect(reviewController != nil)
        defer { reviewController?.retire() }

        fixture.model.section = .pullRequests
        fixture.controller.providerPage.update(
            ProviderPageState(
                section: .pullRequests, signals: [item],
                reports: [ProviderReport(provider: .github, items: [item], status: .connected)]),
            vercel: nil)
        fixture.controller.syncPullRequestWorkspaceMode()
        fixture.controller.view.layoutSubtreeIfNeeded()

        #expect(fixture.controller.providerPage.list.usesSplitDetail)
        #expect(fixture.controller.providerPage.list.select(item))
        #expect(fixture.controller.prWorkspace.activeReview === reviewController?.reviewView)
        #expect(reviewController?.reviewView.presentation == .page)
        #expect(!fixture.controller.prWorkspace.detailHost.isHidden)

        // Below 1,100 pt collapses PR list to compact icons.
        fixture.window.setContentSize(NSSize(width: 980, height: 740))
        fixture.window.layoutIfNeeded()
        #expect(fixture.controller.prWorkspace.bounds.width <= 980)
        #expect(fixture.controller.prWorkspace.layoutState.collapsesListToIcons)
        #expect(fixture.controller.providerPage.isCompact)

        // Below 900 pt falls back to inline review.
        fixture.window.setContentSize(NSSize(width: 840, height: 740))
        fixture.window.layoutIfNeeded()
        #expect(fixture.controller.prWorkspace.bounds.width <= 840)
        #expect(fixture.controller.prWorkspace.layoutState.presentation == .inline)
        #expect(!fixture.controller.providerPage.list.usesSplitDetail)
        #expect(reviewController?.reviewView.presentation == .inline)

        // Back >= 1,150 pt restores full-height side-by-side detail, pop-out hides detail, and `← PRs` clears.
        fixture.window.setContentSize(NSSize(width: 1_200, height: 740))
        fixture.window.layoutIfNeeded()
        #expect(fixture.controller.prWorkspace.activeReview === reviewController?.reviewView)
        #expect(reviewController?.reviewView.presentation == .page)

        reviewController?.popOutToWindow()
        #expect(fixture.controller.prWorkspace.detailHost.isHidden)
        reviewController?.popOutWindow?.window?.close()
        #expect(!fixture.controller.prWorkspace.detailHost.isHidden)

        reviewController?.onBack?()
        #expect(fixture.controller.prWorkspace.activeReview == nil)
        #expect(fixture.controller.providerPage.list.selectedItem == nil)
        _ = target
    }

    @Test func cleanTreeContextBannerRoutingAndPerTabTerminalHeight() async throws {
        let remote = try TemporaryRepository()
        try remote.git("config", "receive.denyCurrentBranch", "ignore")
        let fixture = try await RepositoryWindowFixture { repo in
            try RepositoryWindowFixture.threeCommits(repo)
            try repo.git("remote", "add", "origin", remote.url.path)
            try repo.git("push", "-u", "origin", "main")
            try repo.commit("ahead.txt", "ahead\n", message: "Ahead commit")
        }
        defer { fixture.close() }

        fixture.model.section = .changes
        fixture.controller.updateCleanTreeContext()
        let context = try #require(fixture.controller.filePane.cleanTreeContext)
        #expect(context.lastCommitDate != nil)
        #expect(context.ahead == 1 && context.hasUpstream && context.canPush)
        #expect(CleanTreeEmptyState.showsPushButton(context))
        fixture.controller.filePane.onPush?()
        try await fixture.wait("clean-tree Push forwarded to commands") {
            fixture.commands.calls.contains("push")
        }

        // Sync commands route non-destructive missing-remote/detached notices and failures into ContentBanner.
        let harness = AppShellHarness()
        let repo = try TemporaryRepository()
        try repo.commit("README.md", "one\n", message: "Init")
        let responder = harness.app.commands(for: harness.app.model)
        harness.app.model.open(repo.url)
        await appWaitUntil { harness.app.model.snapshot != nil }
        responder.fetchNow()
        await appWaitUntil { harness.app.model.contentBanner != .none }
        #expect(harness.app.model.contentBanner == .info(String(localized: "This repository has no remote.")))
        #expect(harness.alerts.alerts.isEmpty)
        harness.tearDown()

        // Terminal panel height memory persists per repository tab.
        let defaults = try SetupSandbox().defaults
        let repoTwo = try TemporaryRepository()
        try repoTwo.commit("README.md", "two\n", message: "Second")
        let tabs = RepositoryTabsController(initialModel: AppModel(defaults: defaults), initialURL: repo.url)
        tabs.terminalPanel.defaults = defaults
        tabs.terminalPanel.makeTerminal = { folder, launch in
            TerminalView(session: SessionHarness(launch: launch, folder: folder).session, page: nil)
        }
        let window = UITestSupport.host(tabs, size: NSSize(width: 960, height: 800))
        defer {
            tabs.detach(preserving: AppModel(defaults: defaults))
            window.close()
        }
        tabs.toggleTerminalPanel()
        #expect(tabs.isTerminalPanelShown)
        tabs.terminalPanel.frame.size.height = 360
        let split = try #require(tabs.terminalPanel.superview as? NSSplitView)
        tabs.terminalPanel.splitViewDidResizeSubviews(
            Notification(
                name: NSSplitView.didResizeSubviewsNotification, object: split,
                userInfo: ["NSSplitViewDividerIndex": 0]))
        #expect(abs(tabs.terminalPanel.rememberedShare() - Double(360.0 / split.bounds.height)) < 0.01)
    }

    @Test func blameShortcutMenusSelectionCloseAndRepositoryPillDropTarget() async throws {
        #expect(ShortcutCommand.blame.defaultShortcut == KeyShortcut("b", [.command, .option]))
        #expect(ShortcutCommand.blame.defaultShortcut.display == "⌥⌘B")
        let appHarness = AppShellHarness()
        defer { appHarness.tearDown() }
        let mainMenu = MainMenu.build(target: appHarness.app)
        let viewMenu = mainMenu.item(withTitle: String(localized: "View"))?.submenu
        #expect(viewMenu?.items.contains { $0.identifier == ShortcutCommand.blame.menuIdentifier } == true)

        let fixture = try await RepositoryWindowFixture { repo in
            try RepositoryWindowFixture.threeCommits(repo)
            try repo.git("checkout", "-q", "-b", "feature/pill")
            try repo.commit("pill.txt", "pill\n", message: "Pill branch")
            try repo.git("checkout", "-q", "main")
        }
        defer { fixture.close() }

        let controller = fixture.controller
        try await fixture.selectCommit("Fix the answer")
        controller.selectDetailTab(.changes)
        try await fixture.wait("commit file selected") { fixture.model.selectedFile?.path == "Sources/app.swift" }

        let commitMenu = try #require(controller.commitFileMenu(fixture.model.files))
        let blameMenuItem = try #require(commitMenu.item(titled: String(localized: "Blame")))
        #expect(blameMenuItem.keyEquivalent == "b")
        #expect(blameMenuItem.keyEquivalentModifierMask == [.option, .command])
        blameMenuItem.perform()
        try await fixture.wait("blame shown from file menu") {
            controller.isShowingBlame && controller.blameView?.load.document != nil
        }

        // Blame stays open when clicking a commit block inside BlameView.
        let blameView = try #require(controller.blameView)
        let earlierSHA = controller.historyCommits[1].id
        blameView.onSelectCommit?(earlierSHA)
        try await fixture.wait("commit selected via blame") { fixture.model.selectedCommit?.id == earlierSHA }
        #expect(controller.isShowingBlame)

        // Switching file selection closes blame cleanly.
        controller.chooseChange(FileChange(path: "README.md", indexStatus: " ", worktreeStatus: "M"), staged: false)
        #expect(!controller.isShowingBlame)

        // RepositoryPill accepts branch & commit drag payloads targeting HEAD without silent mutation.
        let pill = RepositoryPill(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        pill.canAcceptDrop = { controller.pillDropOperation(for: $0.pasteboardItems ?? []) }
        pill.onAcceptDrop = { controller.handlePillDrop(items: $0.pasteboardItems ?? [], anchor: $1) }
        #expect(pill.registeredDraggedTypes.contains(GitaDragReference.pasteboardType))

        let root = try #require(controller.model.snapshot?.root.standardizedFileURL.path)
        let branch = GitaDragReference.branch(
            fullName: "refs/heads/feature/pill", name: "feature/pill", isRemote: false)
        #expect(controller.pillDropOperation(for: [branch.pasteboardItem(repositoryRoot: root)]) == .move)
        let items = [GitaDragReference.commits(ids: [earlierSHA]).pasteboardItem(repositoryRoot: root)]
        #expect(controller.pillDropOperation(for: items) == .copy)
        #expect(controller.handlePillDrop(items: items, anchor: pill))
        try await fixture.wait("cherry-pick confirmation shown on pill drop") {
            RepositoryWindowFixture.alerts.contains { $0.contains("Cherry-pick") }
        }

        // Preference.registerDefaults covers DiffPreference keys without breaking legacy tabWidth fallback.
        let prefDefaults = try SetupSandbox().defaults
        Preference.registerDefaults(in: prefDefaults)
        #expect(prefDefaults.string(forKey: DiffPreference.layoutKey) == DiffLayout.unified.rawValue)
        #expect(DiffPreference.tabWidth(prefDefaults) == DiffPreference.defaultTabWidth)
        #expect(CodeFont.tabWidth(prefDefaults) == DiffPreference.defaultTabWidth)
        #expect(prefDefaults.object(forKey: DiffPreference.ignoreWhitespaceKey) as? Bool == false)
    }
}
