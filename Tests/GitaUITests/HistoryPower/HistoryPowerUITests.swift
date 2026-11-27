import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("HistoryPower UI Presenters and Views")
@MainActor
struct HistoryPowerUITests {
    private static let sampleSHA1 = String(repeating: "1", count: 40)
    private static let sampleSHA2 = String(repeating: "2", count: 40)

    private static func makeCommit(id: String, subject: String) -> GitCommit {
        GitCommit(id: id, parents: [], subject: subject, author: "Ada", date: Date())
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func reflogActionBadges() {
        UITestSupport.bootstrap()
        let cases: [(ReflogActionKind, String, NSColor)] = [
            (.commit, "Commit", Theme.success), (.amend, "Amend", Theme.needsInputText),
            (.checkout, "Checkout", Theme.working), (.reset, "Reset", Theme.failure), (.rebase, "Rebase", Theme.merged),
            (.merge, "Merge", Theme.running), (.cherryPick, "Cherry-pick", Theme.merged),
            (.pull, "Pull", Theme.running),
            (.branch, "Branch", Theme.working), (.stash, "Stash", Theme.secondaryText),
            (.other, "Action", Theme.secondaryText),
        ]
        for (kind, title, color) in cases {
            let badge = ReflogActionBadge.badge(for: kind)
            #expect(badge.title == title && badge.accentColor == color)
        }
    }

    @Test("ReflogPresenter filters, loads per-file diffs on demand, and builds window")
    func reflogPresenterAndWindow() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        _ = try repo.commit("a.txt", "v1\n", message: "First")
        let service = GitService(root: repo.url)

        let entries = [
            ReflogEntry(
                selector: "HEAD@{0}", commitID: Self.sampleSHA1,
                actionSummary: "reset: moving to HEAD~1", subject: "First", author: "Ada", date: Date(),
                isOrphaned: false),
            ReflogEntry(
                selector: "HEAD@{1}", commitID: Self.sampleSHA2,
                actionSummary: "commit: Lost experiment", subject: "Lost experiment", author: "Ada", date: Date(),
                isOrphaned: true),
        ]
        struct OversizedFileError: LocalizedError {
            var errorDescription: String? { "Diff exceeded 8 MB" }
        }
        let presenter = ReflogPresenter(
            loadReflog: { _, _ in entries },
            loadFiles: { _ in ["huge.bin", "b.swift"] },
            loadFileDiff: { _, path in
                if path == "huge.bin" { throw OversizedFileError() }
                return "+changed \(path ?? "")\n"
            },
            createBranch: { _, _ in }
        )
        presenter.reload()
        try await Self.waitUntil {
            guard !presenter.loadState.isLoading else { return false }
            if case .loading = presenter.diffState { return false }
            return true
        }

        #expect(presenter.visibleEntries.count == 2)
        #expect(presenter.orphanedCount == 1)
        // First-file diff failure must preserve the file list so the user can pick another file.
        #expect(presenter.diffState.files == ["huge.bin", "b.swift"])
        if case .failed(_, _, _, let error) = presenter.diffState {
            #expect(error == "Diff exceeded 8 MB")
        } else {
            Issue.record("Expected failed diff state")
        }
        #expect(presenter.suggestedRecoveryBranchName(for: entries[1]) == "recover-2222222")

        presenter.selectFile("b.swift")
        try await Self.waitUntil {
            if case .loaded(_, _, let path, _) = presenter.diffState, path == "b.swift" { return true }
            return false
        }
        if case .loaded(_, _, _, let text) = presenter.diffState {
            #expect(text.contains("b.swift"))
        } else {
            Issue.record("Expected loaded diff state")
        }

        presenter.setFilter(.orphaned)
        #expect(presenter.visibleEntries.map(\.commitID) == [Self.sampleSHA2])

        presenter.setFilter(.all)
        presenter.setSearchQuery("reset")
        #expect(presenter.visibleEntries.map(\.commitID) == [Self.sampleSHA1])

        let controller = ReflogViewController(service: service, repositoryRoot: repo.url, repositoryName: "TestRepo")
        let window = UITestSupport.host(controller, size: NSSize(width: 960, height: 600))
        defer {
            controller.cancel()
            window.close()
        }
        controller.reload()
        try await Self.waitUntil {
            guard !controller.presenter.loadState.isLoading else { return false }
            if case .loaded = controller.presenter.diffState { return true }
            if case .failed = controller.presenter.diffState { return true }
            return false
        }
        controller.view.layoutSubtreeIfNeeded()
        UITestSupport.render(controller.view)
    }

    @Test("LineHistoryPresenter and CodeSearchPresenter manage lifecycle, per-file diffs, and inline views")
    func lineHistoryAndCodeSearchUI() async throws {
        UITestSupport.bootstrap()
        let commit = Self.makeCommit(id: Self.sampleSHA1, subject: "Refactor parser")
        let range = LineRangeSpec(path: "Sources/Parser.swift", startLine: 10, endLine: 20)
        let linePresenter = LineHistoryPresenter(range: range) { _, _ in
            [
                LineHistoryEntry(
                    commit: commit,
                    diffText: "@@ -10,2 +10,3 @@\n+let fast = true\n",
                    addedLines: 1,
                    removedLines: 0
                )
            ]
        }
        linePresenter.reload()
        try await Self.waitUntil { !linePresenter.state.isLoading }
        #expect(linePresenter.entries.count == 1)
        #expect(linePresenter.selectedEntry?.commit.id == Self.sampleSHA1)

        let lineController = LineHistoryViewController(presenter: linePresenter)
        let lineWin = UITestSupport.host(lineController, size: NSSize(width: 960, height: 600))
        defer {
            lineController.cancel()
            lineWin.close()
        }
        #expect(linePresenter.headerTitle.contains("L10–L20"))
        lineController.view.layoutSubtreeIfNeeded()
        UITestSupport.render(lineController.view)

        let searchPresenter = CodeSearchPresenter(
            searcher: { _ in
                [PickaxeMatch(commit: commit, matchedFiles: ["Sources/Parser.swift", "Sources/Other.swift"])]
            },
            loadFileDiff: { _, path in "@@ -1,1 +1,2 @@\n+fast in \(path ?? "")\n" }
        )
        #expect(!searchPresenter.canSearch)
        searchPresenter.setPattern(" fast ")
        searchPresenter.setMode(.regex)
        searchPresenter.setPathFilter("Sources")
        searchPresenter.setIgnoreCase(true)
        #expect(searchPresenter.canSearch)
        searchPresenter.search()
        try await Self.waitUntil {
            guard !searchPresenter.state.isSearching else { return false }
            if case .loading = searchPresenter.diffState { return false }
            return true
        }
        #expect(searchPresenter.matches.count == 1)
        #expect(searchPresenter.diffState.selectedPath == "Sources/Parser.swift")

        searchPresenter.selectFile("Sources/Other.swift")
        try await Self.waitUntil {
            if case .loaded(_, let path, _) = searchPresenter.diffState, path == "Sources/Other.swift" { return true }
            return false
        }
        if case .loaded(_, _, let text) = searchPresenter.diffState {
            #expect(text.contains("Sources/Other.swift"))
        } else {
            Issue.record("Expected loaded code search diff")
        }

        let searchController = CodeSearchViewController(presenter: searchPresenter, repositoryName: "TestRepo")
        let searchWin = UITestSupport.host(searchController, size: NSSize(width: 960, height: 600))
        defer {
            searchController.cancel()
            searchWin.close()
        }
        searchController.view.layoutSubtreeIfNeeded()
        UITestSupport.render(searchController.view)
    }

    @Test("Inline History Power VCs support Back action, SF Symbol controls, theme changes, and lifecycle")
    func inlineHistoryToolControllers() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        _ = try repo.commit("a.txt", "hello\n", message: "First")
        let service = GitService(root: repo.url)

        let reflogVC = ReflogViewController(service: service, repositoryRoot: repo.url, repositoryName: "TestRepo")
        reflogVC.loadViewIfNeeded()
        let reflogBack = try #require(
            SheetsSupport.view("historyTool.back", in: reflogVC.view, as: PartsButton.self))
        #expect(reflogBack.isHidden)
        var backClicks = 0
        reflogVC.onBack = { backClicks += 1 }
        #expect(!reflogBack.isHidden)
        #expect(reflogBack.accessibilityPerformPress() && backClicks == 1)
        let filterControl = try #require(
            SheetsSupport.view("reflog.filter", in: reflogVC.view, as: NSSegmentedControl.self))
        #expect(filterControl.segmentCount == ReflogFilter.ordered.count)
        for idx in 0..<filterControl.segmentCount {
            #expect(filterControl.image(forSegment: idx) != nil)
        }
        reflogVC.reload(ref: "HEAD")
        NotificationCenter.default.post(name: .gitaThemeChanged, object: nil)
        reflogVC.view.layoutSubtreeIfNeeded()
        UITestSupport.render(reflogVC.view)
        reflogVC.cancel()

        let searchVC = CodeSearchViewController(
            service: service, repositoryRoot: repo.url, repositoryName: "TestRepo")
        searchVC.loadViewIfNeeded()
        let searchBack = try #require(
            SheetsSupport.view("historyTool.back", in: searchVC.view, as: PartsButton.self))
        #expect(searchBack.isHidden)
        searchVC.onBack = { backClicks += 1 }
        #expect(!searchBack.isHidden)
        #expect(searchBack.accessibilityPerformPress() && backClicks == 2)
        let modeControl = try #require(
            SheetsSupport.view("codeSearch.mode", in: searchVC.view, as: NSSegmentedControl.self))
        #expect(modeControl.image(forSegment: 0) != nil && modeControl.image(forSegment: 1) != nil)
        searchVC.show(initialPattern: "hello", pathFilter: "a.txt")
        searchVC.focusQuery()
        NotificationCenter.default.post(name: .gitaThemeChanged, object: nil)
        searchVC.view.layoutSubtreeIfNeeded()
        UITestSupport.render(searchVC.view)
        searchVC.cancel()

        let range = LineRangeSpec(path: "a.txt", startLine: 1, endLine: 1)
        let lineVC = LineHistoryViewController(service: service, range: range, repositoryRoot: repo.url)
        lineVC.loadViewIfNeeded()
        let lineBack = try #require(
            SheetsSupport.view("historyTool.back", in: lineVC.view, as: PartsButton.self))
        #expect(lineBack.isHidden)
        lineVC.onBack = { backClicks += 1 }
        #expect(!lineBack.isHidden)
        #expect(lineBack.accessibilityPerformPress() && backClicks == 3)
        lineVC.reload(range: range)
        NotificationCenter.default.post(name: .gitaThemeChanged, object: nil)
        lineVC.view.layoutSubtreeIfNeeded()
        UITestSupport.render(lineVC.view)
        lineVC.cancel()
    }

    @Test("BisectBannerModel, BisectBannerView, and BisectStartSheet cover active, finished, and custom terms")
    func bisectBannerAndStartSheet() {
        UITestSupport.bootstrap()

        let inactiveModel = BisectBannerModel(state: .inactive, action: .idle)
        #expect(inactiveModel.isHidden)

        let session = BisectSession(
            startBranch: "main",
            currentCommitID: Self.sampleSHA1,
            currentSubject: "Very long commit subject that should truncate cleanly in narrow windows",
            badTerm: "new",
            goodTerm: "old",
            badCommitID: Self.sampleSHA2,
            goodCommitIDs: [Self.sampleSHA1],
            skippedCommitIDs: [],
            remainingCommits: 7,
            estimatedSteps: 3
        )
        let activeModel = BisectBannerModel(state: .active(session), action: .idle)
        #expect(!activeModel.isHidden)
        #expect(activeModel.shortSHA == "1111111")
        #expect(activeModel.goodButtonTitle == "Old")
        #expect(activeModel.badButtonTitle == "New")
        #expect(activeModel.stepsBadgeText?.contains("~3 steps") == true)

        let culprit = BisectCulprit(
            commitID: Self.sampleSHA2, subject: "Introduces crash", author: "Ada", startBranch: "main")
        let finishedModel = BisectBannerModel(state: .finished(culprit), action: .idle)
        #expect(finishedModel.isFinished)
        #expect(finishedModel.showsOpenCommit)
        #expect(finishedModel.culpritCommitID == Self.sampleSHA2)

        let banner = BisectBannerView(frame: NSRect(x: 0, y: 0, width: 640, height: BisectBannerView.height))
        banner.apply(activeModel)
        banner.layoutSubtreeIfNeeded()
        UITestSupport.render(banner)

        banner.apply(finishedModel)
        banner.layoutSubtreeIfNeeded()
        UITestSupport.render(banner)

        var startState = BisectStartState(badRef: "HEAD", goodRef: "")
        #expect(!startState.canStart)
        startState.goodRef = "HEAD"
        #expect(!startState.canStart)
        startState.goodRef = "v1.0"
        #expect(startState.canStart)
        #expect(BisectStartSheet.extractReference(from: "11111111 · Initial commit") == "11111111")

        let sheet = BisectStartSheet(
            recentCommits: [Self.makeCommit(id: Self.sampleSHA1, subject: "Initial commit")],
            initialBad: "HEAD",
            initialGood: Self.sampleSHA1,
            onStart: { _, _ in }
        )
        #expect(sheet.window != nil)
        #expect(sheet.state.canStart)
    }

    @Test("BisectPresenter coalesces refresh during busy step, syncs state on failure, and surfaces refresh errors")
    func bisectPresenterRaceAndFailurePaths() async throws {
        let session = BisectSession(
            startBranch: "main",
            currentCommitID: Self.sampleSHA1,
            currentSubject: "Step 1",
            badCommitID: Self.sampleSHA2,
            goodCommitIDs: [Self.sampleSHA1],
            skippedCommitIDs: [],
            remainingCommits: 2,
            estimatedSteps: 1
        )
        let syncedAfterFail = BisectSession(
            startBranch: "main",
            currentCommitID: Self.sampleSHA2,
            currentSubject: "After skip",
            badCommitID: Self.sampleSHA2,
            goodCommitIDs: [Self.sampleSHA1],
            skippedCommitIDs: [Self.sampleSHA1],
            remainingCommits: 0,
            estimatedSteps: 0
        )

        struct RefreshReadError: LocalizedError {
            var errorDescription: String? { "Bisect state read failed" }
        }
        actor Counter {
            let synced: BisectSession
            var readCount = 0
            var failReads = false
            init(synced: BisectSession) { self.synced = synced }
            func nextRead() throws -> BisectState {
                readCount += 1
                if failReads { throw RefreshReadError() }
                return .active(synced)
            }
            func setFailReads(_ value: Bool) { failReads = value }
        }
        let counter = Counter(synced: syncedAfterFail)

        let presenter = BisectPresenter(
            operations: BisectPresenter.Operations(
                readState: { try await counter.nextRead() },
                start: { _, _ in
                    try await Task.sleep(for: .milliseconds(40))
                    return .active(session)
                },
                markGood: { .active(session) },
                markBad: { .active(session) },
                skip: { throw BisectError.onlySkippedRemaining("Only skipped commits left") },
                reset: { .inactive }
            )
        )

        // Start bisect while calling refresh() mid-flight: refresh must coalesce and run AFTER start completes.
        let startTask = Task { try await presenter.start(bad: Self.sampleSHA2, good: Self.sampleSHA1) }
        try await Self.waitUntil { presenter.action.isBusy }
        presenter.refresh()
        #expect(await counter.readCount == 0)
        try await startTask.value
        try await Self.waitUntil { await counter.readCount >= 1 }
        #expect(presenter.state == .active(syncedAfterFail))

        // Failed skip re-reads state AND preserves failure message even across an unchanged watcher refresh.
        presenter.skip()
        try await Self.waitUntil { presenter.action.errorMessage != nil }
        #expect(presenter.action.errorMessage?.contains("Only skipped commits left") == true)
        #expect(presenter.state == .active(syncedAfterFail))

        let countBeforeWatcher = await counter.readCount
        presenter.refresh()
        try await Self.waitUntil { await counter.readCount > countBeforeWatcher }
        #expect(presenter.action.errorMessage?.contains("Only skipped commits left") == true)

        // Refresh error surfaces in action state instead of being swallowed.
        await counter.setFailReads(true)
        presenter.refresh()
        try await Self.waitUntil {
            presenter.action.errorMessage == "Bisect state read failed"
        }
        #expect(presenter.bannerModel.errorMessage == "Bisect state read failed")
    }
}
