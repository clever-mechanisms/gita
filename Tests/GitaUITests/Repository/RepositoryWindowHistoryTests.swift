import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The repository window over a real repository: the history list, its header, search and the detail pane.
@MainActor
@Suite("Repository window · history", .serialized)
struct RepositoryWindowHistoryTests {
    @Test func opensTheRepositoryAndListsItsHistory() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        #expect(fixture.controller.historyCommits.map(\.subject) == ["Fix the answer", "Add app", "Add README"])
        #expect(fixture.historyTable.numberOfRows == 3)
        #expect(fixture.historyTable.tableColumns.first?.title == "History · main")
        #expect(fixture.controller.welcome.isHidden)
        #expect(!fixture.controller.strip.isHidden)
        #expect(fixture.controller.pagePane.isHidden)
        #expect(fixture.controller.operationBar.isHidden)
        // Every column draws a cell for every row.
        for column in 0..<fixture.historyTable.numberOfColumns
        where !fixture.historyTable.tableColumns[column].isHidden {
            for row in 0..<3 {
                #expect(fixture.historyTable.view(atColumn: column, row: row, makeIfNecessary: true) != nil)
            }
        }
        UITestSupport.render(fixture.controller.view)
    }

    @Test func selectingACommitShowsItsDetailFilesAndTree() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        try await fixture.selectCommit("Fix the answer")
        let controller = fixture.controller
        #expect(controller.detailTab == .commit)
        #expect(!controller.commitDetail.isHidden)
        #expect(controller.filesSplit.isHidden)
        #expect(fixture.historyTable.selectedRow == 0)

        controller.selectDetailTab(.changes)
        try await fixture.wait("the commit's files") { !fixture.model.files.isEmpty }
        #expect(controller.filesSplit.isHidden == false)
        #expect(controller.commitDetail.isHidden)
        #expect(fixture.model.files.map(\.path) == ["Sources/app.swift"])
        controller.update(.selection)
        #expect(controller.filePane.content == .commitFiles)
        try await fixture.wait("the diff") { fixture.model.diff.contains("+let answer = 42") }
        controller.update(.diff)
        #expect(controller.codePaneState.path == "Sources/app.swift")

        controller.selectDetailTab(.tree)
        try await fixture.wait("the tree review") { fixture.model.isTreeReview }
        controller.update(.selection)
        #expect(controller.filePane.content == .tree)
        controller.selectDetailTab(.commit)
        #expect(!controller.commitDetail.isHidden)
    }

    @Test func theHighlightFollowsTheSelectionAndClearingItReachesTheModel() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        try await fixture.selectCommit("Add README")
        #expect(fixture.historyTable.selectedRow == 2)

        // A search that leaves the selected commit out: no row stays highlighted.
        controller.searchHistory("answer")
        try await fixture.wait("the search results") { controller.historyCommits.map(\.subject) == ["Fix the answer"] }
        #expect(fixture.historyTable.selectedRow == -1)
        #expect(fixture.model.selectedCommit?.subject == "Add README")

        try await fixture.selectCommit("Fix the answer")
        fixture.historyTable.deselectAll(nil)
        #expect(fixture.model.selectedCommit == nil)
        #expect(fixture.model.commitDetails == nil)
    }

    @Test func searchNarrowsTheListAndAllBranchesBringsItBack() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.historyControls.search.stringValue = "answer"
        controller.searchHistory("answer")
        try await fixture.wait("the search results") {
            fixture.model.isSearchingHistory && controller.historyCommits.map(\.subject) == ["Fix the answer"]
        }
        #expect(!controller.historyControls.allBranches.isHidden)
        #expect(controller.historyTable.table.tableColumns.first?.title == "History · Search")
        // Search results are not an ancestry walk: no merge flair.
        #expect(controller.historyFlair(for: controller.historyCommits[0]) == nil)

        controller.chooseSearchField(.author)
        try await fixture.wait("the author search") { fixture.model.searchField == .author }

        controller.showAllBranches()
        try await fixture.wait("all commits") { !fixture.model.isSearchingHistory }
        try await fixture.wait("the whole list") { controller.historyCommits.count == 3 }
        #expect(controller.historyControls.search.stringValue.isEmpty)
    }

    @Test func aBranchFocusAndItsHeader() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let controller = fixture.controller
        let feature = try #require(fixture.model.snapshot?.references.first { $0.name == "feature/login" })
        fixture.model.focusHistory(on: feature)
        try await fixture.wait("the branch's history") {
            fixture.model.focusedReference != nil && controller.historyCommits.first?.subject == "Turn login off"
        }
        #expect(controller.historyTable.table.tableColumns.first?.title == "History · feature/login")
        #expect(controller.historyTable.header.toolTip?.hasPrefix("refs/heads/feature/login") == true)
        #expect(controller.sidebarSelectionID == .reference(fullName: "refs/heads/feature/login"))

        controller.showAllBranches()
        try await fixture.wait("all commits") { fixture.model.focusedReference == nil }
    }

    @Test func jumpingToAReferenceSelectsItsCommit() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let controller = fixture.controller
        let tag = try #require(fixture.model.snapshot?.references.first { $0.name == "v1.0" })
        controller.jumpTo(tag)
        try await fixture.wait("the tagged commit") { fixture.model.selectedCommit?.id == tag.commit }
        #expect(
            controller.historyTable.table.selectedRow == controller.historyCommits.firstIndex { $0.id == tag.commit })
        #expect(fixture.model.section == .history)

        controller.selectCommit(id: try #require(controller.historyCommits.last?.id))
        try await fixture.wait("the first commit") { fixture.model.selectedCommit?.subject == "Add README" }
    }

    @Test func aMergeShowsWhoMergedAndItsCommits() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let controller = fixture.controller
        let merge = try #require(controller.historyCommits.first { $0.subject == "Merge feature/login" })
        let row = try #require(controller.historyCommits.firstIndex(of: merge))
        let flair = try #require(controller.historyFlair(for: merge))
        #expect(flair.count == "2 commits")
        #expect(flair.mergedBy == "Gita Tests")
        #expect(flair.tooltip == "Merged by Gita Tests\n2 commits")
        #expect(controller.historyFlair(for: try #require(controller.historyCommits.last)) == nil)

        // The merge chip opens the list of what it brought in (an offscreen window shows no popover).
        let cell = try #require(
            fixture.historyTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? HistoryCommitCell)
        let chip = NSRect(x: 0, y: 0, width: 20, height: 10)
        controller.historyMergeChip(.click(id: merge.id, rect: chip, view: cell))
        #expect(controller.mergedPopover.shownID == merge.id)
        controller.mergedPopover.checkHover()
        controller.historyMergeChip(.click(id: merge.id, rect: chip, view: cell))
        controller.historyMergeChip(.hover(id: merge.id, rect: chip, view: cell))
        controller.historyMergeChip(.hoverEnded)
        controller.historyMergeChip(.hide(id: merge.id))
        #expect(!controller.mergedPopover.isShown)

        // Hiding the merge label updates the history table in real time while keeping the graph merge node.
        UITestSupport.render(cell)
        #expect(cell.message.mergeChipRect != nil)
        Preference.showsMergeLabel.set(false, fixture.defaults)
        #expect(!controller.historyTable.showsMergeLabel)
        let hiddenCell = try #require(
            fixture.historyTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? HistoryCommitCell)
        UITestSupport.render(hiddenCell)
        #expect(hiddenCell.message.mergeChipRect == nil)
        #expect(hiddenCell.graph.merge != nil)

        Preference.showsMergeLabel.set(true, fixture.defaults)
        #expect(controller.historyTable.showsMergeLabel)
        let restoredCell = try #require(
            fixture.historyTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? HistoryCommitCell)
        UITestSupport.render(restoredCell)
        #expect(restoredCell.message.mergeChipRect != nil)
    }

    @Test func theAuthorMenuHighlightsAndFilters() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        try await fixture.selectCommit("Add app")
        let menu = try #require(fixture.historyTable.menu)
        controller.historyMenu.menuNeedsUpdate(menu)
        let author = try #require(menu.items.first { $0.title == "Gita Tests" })
        try #require(author.submenu?.item(titled: "Highlight")).perform()
        try await fixture.wait("the highlight") { fixture.model.highlightedAuthor != nil }
        #expect(!controller.historyControls.stopHighlighting.isHidden)
        #expect(controller.historyTable.highlightedAuthor?.name == "Gita Tests")

        controller.historyMenu.menuNeedsUpdate(menu)
        try #require(menu.item(titled: "Filter")).perform()
        #expect(fixture.commands.calls.contains("openAuthorTab Gita Tests"))

        // The fixed items stay once; the per-commit items are rebuilt on each opening.
        controller.historyMenu.menuNeedsUpdate(menu)
        #expect(menu.items.filter { $0.title == "Copy SHA" }.count == 1)
        #expect(menu.item(titled: "New Branch…") != nil)

        fixture.model.highlightAuthor(nil)
        #expect(controller.historyControls.stopHighlighting.isHidden)
    }

    @Test func theZoomScalesRowsAndColumns() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let normal = fixture.historyTable.rowHeight
        fixture.defaults.set(150, forKey: Preference.historyZoomPercent.rawValue)
        fixture.model.emit(.section)
        #expect(fixture.historyTable.rowHeight > normal)
        #expect(controller.historyTable.scale == 1.5)
        #expect(fixture.historyTable.column(.author)?.width == 225)
    }

    @Test func historyDetailsHideAndShowTheDetailPane() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        #expect(controller.bottom.superview != nil)
        fixture.model.toggleHistoryDetails()
        controller.update(.historyAppearance)
        #expect(controller.bottom.superview == nil)
        fixture.model.toggleHistoryDetails()
        controller.update(.historyAppearance)
        #expect(controller.bottom.superview != nil)
    }
}
