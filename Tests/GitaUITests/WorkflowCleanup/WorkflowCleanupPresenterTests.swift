import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct WorkflowCleanupPresenterTests {
    @MainActor @Test func utilityLayoutLeavesRoomForTheTableAndFooter() throws {
        UITestSupport.bootstrap()
        let content = WorkflowWindowContent(
            title: "Stacked Branches", repositoryName: "sandbox", symbol: "square.stack.3d.up",
            actionTitle: "Restack", actionSymbol: "arrow.triangle.2.circlepath")
        let root = try #require(content.window.contentView)
        content.setActionTitle("Restack Chain…", symbol: "arrow.triangle.2.circlepath")
        content.feedback("Complete", emptyMessage: "No stacks")
        content.feedback("Error", emptyMessage: "Failed", isError: true)
        content.showsControls = false
        let pillWithIcon = WorkflowWindowContent.pill("Merged", symbol: "checkmark.circle.fill", color: Theme.success)
        let plainPill = WorkflowWindowContent.pill("↑2 ↓1")
        #expect(pillWithIcon.fittingSize.width > 0 && plainPill.fittingSize.width > 0)
        root.layoutSubtreeIfNeeded()
        let scroll = try #require(content.table.enclosingScrollView)
        #expect(scroll.bounds.width > 600)
        #expect(scroll.bounds.height > 200)
        #expect(scroll.isHidden)
        #expect(content.empty.bounds.width > 500)
        #expect(content.action.frame.height > 0)
        #expect(!content.window.isVisible)
        #expect(content.window.title.contains("sandbox"))
        content.stopObservingTheme()
    }

    @MainActor @Test func createStashSheetBuildsFileTreePreview() throws {
        UITestSupport.bootstrap()
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: true)
        let changes = [
            FileChange(path: "src/formatter.swift", indexStatus: " ", worktreeStatus: "M"),
            FileChange(path: "README.md", indexStatus: "?", worktreeStatus: "?"),
        ]
        var presentedSheet: NSWindow?
        var completed: Bool?
        let alerts = AlertPresenter(
            show: { _, _, _ in },
            beginSheet: { sheet, _, done in
                presentedSheet = sheet
                sheet.contentView?.layoutSubtreeIfNeeded()
                done(.cancel)
            })
        CreateStashSheet.present(
            on: parent, alerts: alerts, changes: changes, selectedPaths: ["src/formatter.swift"],
            execute: { _ in }, completion: { completed = $0 })
        let sheet = try #require(presentedSheet)
        let root = try #require(sheet.contentView)
        let filesViews = collectViews(in: root, ofType: ChangedFilesView.self)
        #expect(filesViews.count == 1)
        #expect(filesViews.first?.hasFiles == true)
        #expect(completed == false)
    }

    @MainActor @Test func cleanupAndStackControllersRenderRows() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("a.txt", "base\n", message: "Initial")
        try repo.git("checkout", "-q", "-b", "merged-feature")
        try repo.git("checkout", "-q", "main")
        try repo.git("checkout", "-q", "-b", "stack-a")
        try repo.commit("b.txt", "a\n", message: "Layer A")
        try repo.git("checkout", "-q", "-b", "stack-b")
        try repo.commit("c.txt", "b\n", message: "Layer B")
        try repo.git("checkout", "-q", "main")
        try repo.commit("main.txt", "main\n", message: "Advance main")
        let worktreeURL = repo.url.deletingLastPathComponent().appendingPathComponent("wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: worktreeURL) }
        try repo.git("worktree", "add", "-q", "-b", "wt-branch", worktreeURL.path)
        try FileManager.default.removeItem(at: worktreeURL)

        let service = GitService(root: repo.url)
        let cleanup = CleanupAssistantWindowController(gitService: service, repositoryName: "demo")
        cleanup.present()
        defer { cleanup.window?.orderOut(nil) }
        for _ in 0..<40 where cleanup.numberOfRows(in: NSTableView()) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let cleanupCount = cleanup.numberOfRows(in: NSTableView())
        #expect(cleanupCount >= 2)
        for index in 0..<cleanupCount {
            #expect(cleanup.tableView(NSTableView(), viewFor: nil, row: index) != nil)
        }

        let stacks = BranchStackWindowController(gitService: service, repositoryName: "demo")
        stacks.present()
        defer { stacks.window?.orderOut(nil) }
        for _ in 0..<40 where stacks.numberOfRows(in: NSTableView()) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let stackCount = stacks.numberOfRows(in: NSTableView())
        #expect(stackCount == 3)
        for index in 0..<stackCount {
            #expect(stacks.tableView(NSTableView(), viewFor: nil, row: index) != nil)
        }
    }

    @MainActor private func collectViews<T: NSView>(in view: NSView, ofType _: T.Type) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews { found.append(contentsOf: collectViews(in: subview, ofType: T.self)) }
        return found
    }

    @Test func filterAndBadgeTitles() {
        #expect(CleanupFilter.allCases.map(\.title) == ["All", "Merged", "Gone Upstream", "Stale", "Worktrees"])
        #expect(CleanupFilter.allCases.allSatisfy { !$0.symbolName.isEmpty })
        let badges: [CleanupBadge] = [
            .merged, .goneUpstream, .stale, .unmergedWarning, .dirtyWarning, .prunable, .failed,
        ]
        #expect(badges.map(\.title) == ["Merged", "Gone Upstream", "Stale", "Unmerged", "Dirty", "Prunable", "Failed"])
        #expect(badges.allSatisfy { !$0.symbolName.isEmpty })
    }

    @Test func stashScopesAndLifecycle() throws {
        let changes = [
            FileChange(path: "index", indexStatus: "M", worktreeStatus: " "),
            FileChange(path: "work", indexStatus: " ", worktreeStatus: "M"),
            FileChange(path: "new", indexStatus: "?", worktreeStatus: "?"),
        ]
        var presenter = CreateStashPresenter(changes: changes, selectedPaths: ["new"])
        #expect(presenter.state == .idle && presenter.affectedChanges.count == 3)
        #expect(presenter.fileCountText == "3 files" && presenter.scopeSymbols.count == 4)
        presenter.selectScope(.trackedOnly)
        presenter.setKeepIndex(true)
        #expect(presenter.keepIndex && presenter.affectedChanges.map(\.path) == ["index", "work"])
        presenter.selectScope(.stagedOnly)
        #expect(!presenter.canKeepIndex && !presenter.keepIndex && presenter.affectedChanges.map(\.path) == ["index"])
        presenter.selectScope(.selectedPaths(["new"]))
        #expect(
            presenter.affectedChanges.map(\.path) == ["new"] && presenter.fileCountText == "1 file"
                && presenter.canSubmit)
        presenter.message = "bad\0message"
        #expect(!presenter.canSubmit)
        presenter.message = "save"
        #expect(presenter.begin() == .init(message: "save", scope: .selectedPaths(["new"])))
        #expect(presenter.isRunning && presenter.status.isBusy && presenter.begin() == nil)
        presenter.fail("failure")
        #expect(presenter.status.isError && presenter.status.message == "failure" && presenter.canSubmit)
        #expect(presenter.begin() != nil)
        presenter.finish()
        #expect(presenter.state == .idle)
        var empty = CreateStashPresenter(changes: [], selectedPaths: [])
        empty.selectScope(.selectedPaths([]))
        #expect(empty.scope == .allIncludingUntracked && !empty.canSubmit)
    }

    @Test func stashActionsAndConfirmation() {
        #expect(StashActionPresenter.items.map(\.action) == [.pop, .apply, .createBranch, .drop])
        let stash = GitStash(ref: "stash@{1}", subject: "saved changes")
        let copy = StashActionPresenter.dropConfirmation(stash)
        #expect(copy.title.contains("stash@{1}") && copy.informativeText.contains("saved changes"))
        #expect(copy.confirmTitle == String(localized: "Drop Stash"))
        #expect(StashActionPresenter.popRecoveryPrompt(for: .applied, stash: stash) == nil)
        let conflict = StashActionPresenter.popRecoveryPrompt(for: .conflictedStashKept("merge"), stash: stash)
        #expect(conflict?.title.contains("stash@{1}") == true && conflict?.informativeText.contains("merge") == true)
        let indexRetry = StashActionPresenter.popRecoveryPrompt(
            for: .indexConflictRetryWithoutIndex("index"), stash: stash)
        #expect(indexRetry?.confirmTitle.contains("Index") == true)
        #expect(StashActionPresenter.validBranchName("feature/restore"))
        for bad in ["", "HEAD", "-bad", "bad//part", ".hidden", "a/.bad", "a.lock", "foo..bar", "bad\nref", "@{-1}"] {
            #expect(!StashActionPresenter.validBranchName(bad))
        }
    }

    private var report: CleanupScanReport {
        var report = CleanupScanReport(defaultBranch: "main")
        report.branches = [
            .init(name: "done", commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ageDays: 1, reasons: [.merged]),
            .init(
                name: "old", commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", ageDays: 90,
                reasons: [.goneUpstream, .stale(days: 90)]),
        ]
        report.worktrees = [
            .init(worktree: .init(path: "/dirty", branch: "wip", head: "b"), idleDays: 45, isDirty: true),
            .init(
                worktree: .init(path: "/missing", branch: nil, head: "a", isPrunable: true), idleDays: 0, isDirty: false
            ),
        ]
        return report
    }

    @Test func cleanupFiltersAndSelectionAcrossFilters() throws {
        var presenter = CleanupAssistantPresenter()
        let id = presenter.startScan()
        presenter.completeScan(report, id: id)
        #expect(presenter.selectionCount == 0)
        #expect(CleanupFilter.allCases.map { presenter.filterCount(for: $0) } == [4, 1, 1, 1, 2])
        presenter.activeFilter = .stale
        let stale = try #require(presenter.visibleRows().first)
        #expect(stale.badges.contains(.unmergedWarning) && stale.warning != nil && stale.ageText == "3mo")
        presenter.toggleSelection(id: stale.id)
        presenter.activeFilter = .worktrees
        presenter.selectAllVisible()
        #expect(presenter.isAllVisibleSelected && presenter.selectionCount == 3)
        #expect(presenter.visibleRows().first?.badges == [.dirtyWarning])
        #expect(presenter.visibleRows().first?.subtitle == "wip")
        #expect(presenter.visibleRows().first?.displayTitle == "wip")
        #expect(presenter.visibleRows().first?.detailText.contains("/dirty") == true)
        #expect(presenter.visibleRows().first?.ageText == "45d")
        #expect(presenter.visibleRows().last?.badges == [.prunable])
        #expect(presenter.visibleRows().last?.displayTitle == "missing")
        #expect(presenter.visibleRows().last?.ageText == "Today")
        #expect(CleanupRowItem.abbreviateHome("/Users/alice/dev/repo", home: "/Users/alice") == "~/dev/repo")
        #expect(CleanupRowItem.abbreviateHome("/tmp/repo", home: "/Users/alice") == "/tmp/repo")
        #expect(presenter.actionButtonTitle == "Clean 3 Items…")
        #expect(presenter.selectionText == "3 of 4 selected")
        presenter.toggleSelection(id: "/dirty")
        #expect(!presenter.isAllVisibleSelected)
        let batch = presenter.buildBatchSelection()
        #expect(batch.branches == ["old": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        #expect(batch.worktreePaths == ["/missing"] && !batch.allowUnmergedBranchDelete)
        let summary = presenter.confirmationSummary()
        #expect(summary.contains("/missing") && summary.contains(".env") && presenter.includesUnmerged)
        presenter.deselectAllVisible()
        #expect(presenter.selectionCount == 1 && presenter.actionButtonTitle == "Clean 1 Item…")
        #expect(presenter.confirmationSummary().contains("old"))
    }

    @Test func cleanupFailuresAndStaleScanCompletion() throws {
        var presenter = CleanupAssistantPresenter()
        let first = presenter.startScan()
        let second = presenter.startScan()
        presenter.completeScan(report, id: first)
        #expect(presenter.scanState == .scanning(id: second))
        presenter.failScan("unavailable", id: second)
        #expect(presenter.scanState.errorMessage == "unavailable" && !presenter.scanState.isScanning)
        let retry = presenter.startScan()
        presenter.completeScan(report, id: retry)
        presenter.selectAllVisible()
        presenter.startCleanup()
        #expect(presenter.runState == .cleaning(count: 4))
        presenter.toggleSelection(id: "/dirty")
        #expect(presenter.selectionCount == 4)
        presenter.failCleanup("failed")
        #expect(presenter.runState == .failed("failed") && presenter.hasStatusError && presenter.status == "failed")
        let result = CleanupBatchResult(
            deletedBranches: ["done"], failures: [.init(target: "/dirty", reason: "dirty tree")])
        presenter.completeCleanup(result)
        #expect(
            presenter.hasStatusError && CleanupAssistantPresenter.failureDetails(for: result).contains("dirty tree"))
        let keepFailuresID = presenter.startScan(clearFailures: false)
        presenter.completeScan(report, id: keepFailuresID)
        let dirtyRow = try #require(presenter.visibleRows().first { $0.id == "/dirty" })
        #expect(dirtyRow.badges.contains(.failed) && dirtyRow.warning == "dirty tree")
        _ = presenter.startScan(clearFailures: true)
        #expect(presenter.selectionCount == 0 && presenter.failuresByTarget.isEmpty)
    }

    @Test func stackRowsReviewAndLifecycle() throws {
        let base = GitReference(name: "main", fullName: "refs/heads/main", commit: "m", kind: .branch)
        let child = GitReference(
            name: "child", fullName: "refs/heads/child", commit: "c", kind: .branch, isCurrent: true)
        let layer = StackLayer(
            reference: child, position: .init(depth: 1, aheadOfBase: 1, behindBase: 2),
            commitSubjects: ["The change"])
        let stack = BranchStack(baseBranch: base.name, baseCommitID: base.commit, layers: [layer])
        var presenter = BranchStackPresenter()
        #expect(presenter.state == .idle && !presenter.canRestack)
        let id = presenter.startLoading()
        presenter.loaded([], id: UUID())
        #expect(presenter.state == .loading(id: id))
        presenter.loaded([stack], id: id)
        #expect(presenter.canRestack && presenter.selected == stack)
        let rows = presenter.rows()
        #expect(rows.map(\.depth) == [0, 1] && rows.first?.needsRestack == true)
        let row = try #require(rows.last)
        #expect(rows.first?.connectorSymbol == nil)
        #expect(row.isCurrent && row.counts.contains("↓2") && row.connectorSymbol == "arrow.turn.down.right")
        #expect(row.summary.contains("The change"))
        let impact = BranchStackRestackPreview.Impact(
            commitsToReplay: [.init(id: "c", parents: [], subject: "The change", author: "", date: .now)],
            branchesToUpdate: ["child"], forkedSiblingBranches: ["side-branch"], blockedByWorktreePaths: ["/occupied"])
        let preview = BranchStackRestackPreview(
            stack: stack, ontoRef: "main", ontoCommitID: "m", currentBranch: "main", impact: impact)
        presenter.preview(preview)
        let copy = BranchStackPresenter.reviewText(preview)
        #expect(copy.contains("switch from main to child") && copy.contains("side-branch"))
        #expect(copy.contains("/occupied") && copy.contains("The change") && copy.contains("--update-refs"))
        presenter.cancelPreview()
        #expect(presenter.state == .loaded([stack]))
        presenter.startRestack(stack)
        #expect(presenter.isRestacking && !presenter.canRestack)
        let state = GitOperationState(kind: .rebase, identity: "conflict")
        presenter.finish(.init(outcome: .stopped(state, "conflicts"), updatedBranches: []), stacks: [stack])
        #expect(presenter.state == .stopped(state, "conflicts") && presenter.hasError && !presenter.canRestack)
        presenter.fail("unreadable")
        #expect(presenter.status == "unreadable" && presenter.hasError)
        let result = BranchStackRestackResult(outcome: .completed, updatedBranches: ["child"])
        presenter.finish(result, stacks: [])
        #expect(presenter.state == .completed(result) && presenter.selected == nil)
    }

    @MainActor @Test func closingStackWindowDoesNotCancelInFlightRestack() async throws {
        UITestSupport.bootstrap()
        let runner = DelayedRestackRunner()
        let service = GitService(root: URL(fileURLWithPath: "/tmp"), runner: runner)
        let controller = BranchStackWindowController(gitService: service)
        let layer = StackLayer(
            reference: GitReference(name: "child", fullName: "refs/heads/child", commit: "c", kind: .branch),
            position: .init(depth: 1, aheadOfBase: 1, behindBase: 1), commitSubjects: ["Fix"])
        let stack = BranchStack(baseBranch: "main", baseCommitID: "m", layers: [layer])
        let preview = BranchStackRestackPreview(
            stack: stack, ontoRef: "main", ontoCommitID: "m", currentBranch: "main",
            impact: .init(commitsToReplay: [], branchesToUpdate: ["child"]))
        controller.restack(preview)
        #expect(!controller.windowShouldClose(try #require(controller.window)))
        await runner.waitUntilStarted()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        let cancelled = await runner.finishAndReportCancellation()
        #expect(!cancelled)
    }
}

private actor DelayedRestackRunner: CommandRunning {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var sawCancellation = false

    func run(
        executable _: String, arguments _: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return CommandResult(stdout: Data(), stderr: Data("done".utf8), exitCode: 1)
    }

    private func recordCancellation() {
        sawCancellation = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in startWaiter = continuation }
    }

    func finishAndReportCancellation() async -> Bool {
        releaseWaiter?.resume()
        releaseWaiter = nil
        return sawCancellation
    }
}
