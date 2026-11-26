import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Working changes row & multi-commit compare (§6b)", .serialized)
struct HistoryWorkingChangesAndCompareTests {
    @Test func historySelectionLifecycleCasesSelectedIDsAndSwapped() {
        let commits = (0..<4).map {
            GitCommit(id: "c\($0)", parents: [], subject: "s\($0)", author: "Ada", email: "a@b.c", date: Date())
        }
        let none = HistorySelection(selectedRows: IndexSet(), commits: commits)
        #expect(none == .none)
        #expect(none.selectedIDs.isEmpty)
        #expect(none.swapped() == .none)

        let one = HistorySelection(selectedRows: IndexSet([1]), commits: commits)
        #expect(one == .commit("c1"))
        #expect(one.selectedIDs == ["c1"])
        #expect(one.swapped() == .commit("c1"))

        let pair = HistorySelection(selectedRows: IndexSet([0, 2]), commits: commits)
        #expect(pair == .pair("c2", "c0"))
        #expect(pair.selectedIDs == ["c0", "c2"])
        #expect(pair.swapped() == .pair("c0", "c2"))

        let many = HistorySelection(selectedRows: IndexSet([0, 1, 3]), commits: commits)
        #expect(many == .many(["c0", "c1", "c3"]))
        #expect(many.selectedIDs == ["c0", "c1", "c3"])
    }

    @Test func workingChangesRowVisibilityAndClickOpensLocalChangesDetailWithoutLeavingAllCommits() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let rowView = controller.historyTable.workingChangesRow

        // Clean working tree: pinned row is hidden.
        #expect(rowView.isHidden)

        // Dirty working tree: pinned row appears above the clip view.
        try fixture.repository.write("Sources/app.swift", "let answer = 99\n")
        try fixture.repository.write("README.md", "# Staged change\n")
        try fixture.repository.git("add", "README.md")
        try await fixture.refresh()

        try await fixture.wait("working changes row shown") { !rowView.isHidden }
        #expect(rowView.state.unstagedCount == 1)
        #expect(rowView.state.stagedCount == 1)
        #expect(rowView.state.summaryText.contains("Working Changes"))
        UITestSupport.render(controller.view)
        #expect(rowView.frame.height == WorkingChangesRowView.height)
        let top = controller.historyTop
        let header = controller.historyTable.header
        let headerFrame = header.convert(header.bounds.intersection(header.visibleRect), to: top)
        let filterFrame = controller.historyControls.search.convert(
            controller.historyControls.search.bounds.intersection(controller.historyControls.search.visibleRect),
            to: top)
        #expect(!headerFrame.isEmpty && top.bounds.intersects(headerFrame))
        #expect(!filterFrame.isEmpty && top.bounds.intersects(filterFrame))
        #expect(!headerFrame.intersects(rowView.frame))
        #expect(!filterFrame.intersects(headerFrame))
        #expect(!controller.historyTable.scroll.frame.intersects(rowView.frame))

        // Clicking Working Changes switches detail to Local Changes while staying in All Commits.
        controller.openWorkingChangesDetail()
        try await fixture.wait("local changes detail overlay") {
            controller.model.isReviewingWorkingChanges
                && controller.filePane.content == .localChanges
                && !controller.commitFooter.isHidden
        }
        #expect(controller.model.section == .history)
        #expect(rowView.state.isSelected)

        // Searching hides the pinned Working Changes row.
        controller.searchHistory("answer")
        try await fixture.wait("pinned row hidden during search") { rowView.isHidden }
    }

    @Test func workingChangesOverlaySurvivesUnstagedSelectionCommitDraftActivityAndRefresh() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller

        try fixture.repository.write("Sources/app.swift", "let answer = 99\n")
        try fixture.repository.write("README.md", "# Staged change\n")
        try fixture.repository.git("add", "README.md")
        try await fixture.refresh()

        controller.openWorkingChangesDetail()
        try await fixture.wait("working changes overlay visible") {
            controller.model.isReviewingWorkingChanges
                && controller.filePane.content == .localChanges
                && !controller.filesSplit.isHidden
                && controller.commitDetail.isHidden
                && !controller.commitFooter.isHidden
        }

        // Selecting an unstaged file keeps the Working Changes view active and does not lose composer focus.
        let unstaged = try #require(controller.model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        controller.chooseChange(unstaged, staged: false)
        try await fixture.wait("unstaged diff loaded") {
            controller.model.selectedFile?.path == "Sources/app.swift"
                && !controller.model.staged
                && !controller.model.isDiffLoading
        }
        #expect(controller.model.isReviewingWorkingChanges)
        #expect(controller.filePane.content == .localChanges)
        #expect(!controller.filesSplit.isHidden)
        #expect(controller.commitDetail.isHidden)

        // Applying a generated commit message (emits .commitDraft and .activity) must stay in Working Changes.
        fixture.window.makeFirstResponder(controller.commitFooter.field)
        let generated = GeneratedCommitMessage(subject: "Update README", body: "", agent: .claude)
        controller.commitFooter.assistController.onApplyMessage?(generated)
        #expect(controller.commitFooter.message == "Update README")
        #expect(controller.model.isReviewingWorkingChanges)
        #expect(!controller.filesSplit.isHidden)
        #expect(controller.commitDetail.isHidden)
        #expect(!controller.commitFooter.isHidden)

        // A repository refresh while changes remain must keep Working Changes instead of jumping back to a commit.
        try fixture.repository.write("Sources/app.swift", "let answer = 100\n")
        try await fixture.refresh()
        #expect(controller.model.isReviewingWorkingChanges)
        #expect(controller.model.selectedCommit == nil)
        #expect(controller.filePane.content == .localChanges)
        #expect(!controller.filesSplit.isHidden)
        #expect(controller.commitDetail.isHidden)
        #expect(!controller.commitFooter.isHidden)
    }

    @Test func twoCommitCompareAndSwap() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let commits = controller.historyCommits
        #expect(commits.count == 3)

        // Select newest (row 0) and oldest (row 2): older=commits[2], newer=commits[0].
        fixture.historyTable.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        try await fixture.wait("compare loaded") {
            fixture.model.historySelection == .pair(commits[2].id, commits[0].id)
                && fixture.model.compareState?.isLoadingDiff == false
        }
        #expect(fixture.model.selectedCommit == nil)
        #expect(!controller.commitDetail.compareView.isHidden)
        #expect(fixture.model.compareState?.files.map(\.path) == ["Sources/app.swift"])
        #expect(fixture.model.compareState?.diff.contains("+let answer = 42") == true)
        #expect(CommitCompareView.distanceText(fixture.model.compareState?.distance) == "(2 commits apart)")

        // Swap flips comparison direction (`git diff newer older`).
        controller.commitDetail.compareView.onSwap?()
        try await fixture.wait("swapped compare loaded") {
            fixture.model.historySelection == .pair(commits[0].id, commits[2].id)
                && fixture.model.compareState?.isLoadingDiff == false
                && fixture.model.compareState?.diff.contains("-let answer = 42") == true
        }
    }

    @Test func multiCommitSummaryEligibilityCopySHAsAndSquashPrefill() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let commits = controller.historyCommits
        #expect(commits.count == 3)

        // Add a 4th commit so selecting the top 3 commits has a parent base commit for Squash…
        try fixture.repository.commit("extra.txt", "extra\n", message: "Fourth commit")
        try await fixture.refresh()
        let updated = controller.historyCommits
        #expect(updated.count == 4)

        fixture.historyTable.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        try await fixture.wait("many selection") {
            fixture.model.historySelection == .many([updated[0].id, updated[1].id, updated[2].id])
        }
        #expect(fixture.model.selectedCommit == nil)
        #expect(!controller.commitDetail.multiCommitView.isHidden)

        let eligibility = MultiCommitActionEligibility(
            selectedIDs: [updated[0].id, updated[1].id, updated[2].id],
            commits: updated,
            head: fixture.model.snapshot?.head,
            canOperate: true)
        #expect(eligibility.canCherryPick)
        #expect(eligibility.canRevert)
        #expect(eligibility.canSquash)
        #expect(eligibility.squashBase?.id == updated[3].id)
        #expect(eligibility.squashPrefill[updated[2].id] == .pick)
        #expect(eligibility.squashPrefill[updated[1].id] == .squash)
        #expect(eligibility.squashPrefill[updated[0].id] == .squash)

        // Verify InteractiveRebaseController prefills the squash plan from `squashPrefill`.
        let service = try #require(fixture.model.service)
        let base = try #require(eligibility.squashBase)
        let rebaseSheet = InteractiveRebaseController(
            base: base,
            initialActions: eligibility.squashPrefill,
            onLoad: { try await service.previewInteractiveRebase(after: base.id) },
            onMessage: { id in try await service.commitDetails(ref: id).message },
            onApply: { _, _ in })
        rebaseSheet.sheetDidPresent()
        try await fixture.wait("rebase plan loaded with squash prefill") {
            rebaseSheet.plan.steps.count == 3
        }
        #expect(rebaseSheet.plan.steps.map(\.action) == [.pick, .squash, .squash])
        rebaseSheet.cancelLoads()

        // Multi-commit context menu keeps all 3 selected rows and populates bulk items.
        let menu = try #require(fixture.historyTable.menu)
        controller.historyMenu.menuNeedsUpdate(menu)
        #expect(menu.item(titled: "Cherry-pick 3…") != nil)
        #expect(menu.item(titled: "Revert 3…") != nil)
        #expect(menu.item(titled: "Squash…") != nil)
        #expect(menu.item(titled: "Copy SHAs") != nil)
    }
}
