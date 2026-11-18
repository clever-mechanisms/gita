import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel history: pages, search, branch focus, filters and folded merges")
@MainActor
struct ModelAppModelHistoryTests {
    private static let longHistory = HistoryPage.size + 20

    private func longHarness() async throws -> ModelHarness {
        let harness = try ModelHarness()
        try harness.repository.importCommits(Self.longHistory)
        try await harness.open()
        return harness
    }

    @Test func furtherPagesLoadAndSurviveARefresh() async throws {
        let harness = try await longHarness()
        let model = harness.model
        #expect(model.snapshot?.commits.count == HistoryPage.size)
        #expect(model.displayedHistoryHasMore)
        #expect(model.displayedHistoryIndex != nil)
        #expect(!model.displayedHistoryIsLoading)

        model.loadMore()
        #expect(model.displayedHistoryIsLoading)
        try await harness.settle { model.snapshot?.commits.count == Self.longHistory }
        #expect(!model.displayedHistoryHasMore)
        #expect(model.status == RepositoryStatusText.historyLoaded.rawValue)
        #expect(model.graph.count == Self.longHistory)
        #expect(model.displayedCommits.count == Self.longHistory)
        model.loadMore() // nothing more
        #expect(!model.isLoading)

        try harness.repository.write("file.txt", "edited\n")
        model.refresh()
        try await harness.settle { model.snapshot?.changes.count == 1 }
        #expect(model.snapshot?.commits.count == Self.longHistory)
    }

    @Test func aFailedPageStaysFailedAcrossARefreshUntilTheNextRead() async throws {
        let harness = try await longHarness()
        let model = harness.model
        let missing = String(repeating: "0", count: 40)
        model.focusHistory(on: GitReference(name: "gone", fullName: "refs/heads/gone", commit: missing, kind: .branch))
        try await harness.settle { model.historyPageFailed && !model.displayedHistoryIsLoading }
        #expect(model.status == RepositoryStatusText.historyFailed.rawValue)
        #expect(model.statusIsFailure)
        #expect(model.displayedHistoryHasMore)

        model.refresh()
        try await harness.settle { model.status == RepositoryStatusText.clean.rawValue }
        #expect(model.historyPageFailed)
        #expect(!model.statusIsFailure)

        model.showAllHistory()
        #expect(!model.historyPageFailed)
        model.loadMore()
        try await harness.settle { model.snapshot?.commits.count == Self.longHistory }
        #expect(!model.historyPageFailed)
    }

    @Test func aPageReadDuringAWorkingTreeChangeReadsTheRepositoryAgain() async throws {
        let harness = try await longHarness()
        let model = harness.model
        model.loadMore()
        model.repositoryChanged()
        try await harness.settle { !model.dirty || model.snapshot?.commits.count == Self.longHistory }
    }

    @Test func searchReadsPagesOfResults() async throws {
        let harness = try await longHarness()
        let model = harness.model
        model.searchHistory("Commit", field: .message)
        #expect(model.isSearchingHistory)
        #expect(model.searchQuery == "Commit")
        #expect(model.searchField == .message)
        #expect(model.displayedHistoryIndex == nil)
        let search = await eventually { !model.displayedHistoryIsLoading }
        #expect(search)
        #expect(model.displayedCommits.count == HistoryPage.size)
        #expect(model.displayedHistoryHasMore)

        model.loadMoreSearch()
        let more = await eventually { model.displayedCommits.count == Self.longHistory && !model.search.isSearching }
        #expect(more)
        #expect(!model.displayedHistoryHasMore)
        model.loadMoreSearch() // nothing more

        model.searchHistory("", field: .message)
        #expect(!model.isSearchingHistory)
        #expect(model.displayedCommits.count == HistoryPage.size)
    }

    @Test func aSearchFailureIsLogged() async throws {
        let harness = try await longHarness()
        let model = harness.model
        model.searchHistory("[", field: .commit)
        let done = await eventually { !model.search.isSearching }
        #expect(done)
        if model.status == RepositoryStatusText.searchFailed.rawValue {
            #expect(model.events.first?.title == String(localized: "Search failed"))
        }
    }

    @Test func searchWithoutARepositoryEndsAtOnce() throws {
        let harness = try ModelHarness()
        let model = harness.model
        model.searchHistory("x", field: .message)
        #expect(!model.search.isSearching)
        model.focusHistory(on: GitReference(name: "main", fullName: "refs/heads/main", commit: "a", kind: .branch))
        #expect(model.focusedReference == nil)
    }

    private func branchHarness() async throws -> ModelHarness {
        let harness = try ModelHarness()
        let repository = harness.repository
        try repository.commit("base.txt", "base\n", message: "Base")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.commit("feature.txt", "feature\n", message: "Feature change")
        try repository.git("checkout", "-q", "main")
        try repository.commit("main.txt", "main\n", message: "Main change")
        try await harness.open()
        try await harness.settle { harness.model.commitDetails != nil && !harness.model.isDiffLoading }
        return harness
    }

    private func reference(_ model: AppModel, _ fullName: String) throws -> GitReference {
        try #require(model.snapshot?.references.first { $0.fullName == fullName })
    }

    @Test func aBranchFocusShowsThatBranchAloneAndEnds() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        let selected = model.selectedCommit
        let feature = try reference(model, "refs/heads/feature")
        let identity = model.focusedHistoryIdentity

        model.focusHistory(on: feature)
        #expect(model.focusedReference == feature)
        #expect(model.focusedHistoryIdentity != identity)
        try await harness.settle { model.focusedGraph.count == 2 && model.selectedCommit != nil }
        #expect(model.displayedCommits.map(\.subject) == ["Feature change", "Base"])
        #expect(!model.displayedHistoryHasMore)
        #expect(!model.displayedHistoryIsLoading)
        #expect(model.displayedHistoryIndex?.count == 2)
        #expect(model.mergeHistory.commits.count == 2)
        #expect(model.selectedCommit?.subject == "Feature change")

        // Leaving the History page and coming back selects the focus's first commit again.
        model.section = .changes
        model.selection.clear()
        model.section = .history
        #expect(model.selectedCommit?.subject == "Feature change")

        model.showAllHistory()
        #expect(model.focusedReference == nil)
        #expect(model.selectedCommit?.id == selected?.id)
        #expect(model.mergeHistory.commits.count == 3)
    }

    @Test func aSearchEndsTheFocus() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.focusHistory(on: try reference(model, "refs/heads/feature"))
        try await harness.settle { model.focusedGraph.count == 2 }
        model.searchHistory("Main", field: .message)
        #expect(model.focusedReference == nil)
        let found = await eventually { !model.search.isSearching }
        #expect(found)
        #expect(model.displayedCommits.map(\.subject) == ["Main change"])
    }

    @Test func aFocusOnAMovedBranchFollowsIt() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.focusHistory(on: try reference(model, "refs/heads/main"))
        try await harness.settle { model.focusedGraph.count == 2 }
        try harness.repository.commit("next.txt", "next\n", message: "Next")
        model.refresh()
        // Branch tips committed in the same second can list in either order: look for the commit, not its row.
        try await harness.settle { model.snapshot?.commits.contains { $0.subject == "Next" } == true }
        #expect(model.focusedReference != nil)
    }

    @Test func hidingAndShowingBranchesAloneReScopesTheHistory() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        let sibling = harness.sibling()
        sibling.open(harness.url)
        let siblingOpened = await eventually { sibling.snapshot != nil && !sibling.isLoading }
        #expect(siblingOpened)

        let feature = try reference(model, "refs/heads/feature")
        model.toggleBranchFilter(.pin, feature)
        #expect(model.branchFilters.pinned == [feature.fullName])

        model.toggleBranchFilter(.hide, feature)
        try await harness.settle { model.snapshot?.historyScope == model.branchFilters.scope }
        #expect(model.snapshot?.commits.map(\.subject) == ["Main change", "Base"])
        #expect(model.walksBranchFilters(try #require(model.snapshot)))
        let followed = await eventually { sibling.branchFilters == model.branchFilters && !sibling.isLoading }
        #expect(followed)
        #expect(sibling.snapshot?.commits.count == 2)

        model.toggleBranchFilter(.only, feature)
        try await harness.settle { model.snapshot?.commits.map(\.subject) == ["Feature change", "Base"] }

        model.clearBranchFilters()
        try await harness.settle { model.snapshot?.commits.count == 3 }
        #expect(!model.branchFilters.isFiltering)
        model.clearBranchFilters() // nothing to clear
        sibling.stop()
    }

    @Test func savedBranchFiltersApplyWhenTheRepositoryOpens() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.toggleBranchFilter(.hide, try reference(model, "refs/heads/feature"))
        try await harness.settle { model.snapshot?.commits.count == 2 }

        let sibling = harness.sibling()
        sibling.open(harness.url)
        let opened = await eventually {
            sibling.snapshot?.commits.count == 2 && !sibling.isLoading && sibling.branchFilters.isFiltering
        }
        #expect(opened)
        sibling.stop()
    }

    @Test func aFocusEndsWhenTheFiltersReScope() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        let feature = try reference(model, "refs/heads/feature")
        model.focusHistory(on: feature)
        try await harness.settle { model.focusedGraph.count == 2 }
        model.toggleBranchFilter(.hide, feature)
        #expect(model.focusedReference == nil)
        try await harness.settle { model.snapshot?.commits.count == 2 }
    }

    private func mergedHarness(collapsed: Bool) async throws -> ModelHarness {
        let harness = try ModelHarness()
        let repository = harness.repository
        try repository.commit("base.txt", "base\n", message: "Base")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.commit("feature.txt", "feature\n", message: "Feature change")
        try repository.git("checkout", "-q", "-b", "inner")
        try repository.commit("inner.txt", "inner\n", message: "Inner change")
        try repository.git("checkout", "-q", "feature")
        try repository.merge("inner", message: "Merge inner")
        try repository.git("checkout", "-q", "main")
        try repository.commit("main.txt", "main\n", message: "Main change")
        try repository.merge("feature", message: "Merge feature")
        try repository.commit("after.txt", "after\n", message: "After")
        harness.defaults.set(collapsed, forKey: Preference.collapsesMergedCommits.rawValue)
        try await harness.open()
        return harness
    }

    @Test func collapsedMergesFoldTheirCommitsAndUnfoldOnDemand() async throws {
        let harness = try await mergedHarness(collapsed: true)
        let model = harness.model
        #expect(model.collapsesMerges)
        let merge = try harness.commit("Merge feature")
        let inner = try harness.commit("Inner change")
        #expect(model.collapsedMerge(hiding: inner.id) == merge.id)
        #expect(!model.displayedCommits.contains(inner))
        #expect(model.mergeHistory.commits.contains(inner))

        var revealed = false
        model.reveal(inner.id) { revealed = true }
        let shown = await eventually { revealed }
        #expect(shown)
        #expect(model.isMergeExpanded(merge.id))
        #expect(model.collapsedMerge(hiding: inner.id) == nil)
        #expect(model.displayedCommits.contains(inner))

        var immediate = false
        model.reveal(inner.id) { immediate = true }
        #expect(immediate)

        model.collapseMerge(merge.id)
        let folded = await eventually { model.collapsedMerge(hiding: inner.id) != nil }
        #expect(folded)
        #expect(!model.isMergeExpanded(merge.id))
        model.collapseMerge(merge.id) // already folded

        // Turning the setting off shows every commit again.
        harness.defaults.set(false, forKey: Preference.collapsesMergedCommits.rawValue)
        NotificationCenter.default.post(
            name: .gitaPreferenceChanged, object: nil,
            userInfo: ["key": Preference.collapsesMergedCommits.rawValue])
        let unfolded = await eventually { !model.collapsesMerges }
        #expect(unfolded)
        #expect(model.displayedCommits.count == model.snapshot?.commits.count)
    }

    @Test func squashMergesLinkTheirBranchTips() async throws {
        let harness = try ModelHarness()
        let repository = harness.repository
        try repository.commit("base.txt", "base\n", message: "Base")
        try repository.git("checkout", "-q", "-b", "topic")
        try repository.commit("topic.txt", "topic\n", message: "Topic change")
        try repository.git("checkout", "-q", "main")
        try repository.git("merge", "-q", "--squash", "topic")
        try repository.git("commit", "-q", "-m", "Squashed topic")
        harness.defaults.set(true, forKey: Preference.squashMergesAsMerges.rawValue)
        try await harness.open()
        let model = harness.model
        let squash = try harness.commit("Squashed topic")
        let tip = try harness.commit("Topic change")
        let linked = await eventually { !model.squashLinks.isEmpty }
        #expect(linked)
        #expect(model.squashLinks[squash.id] == tip.id)
        let laidOut = await eventually { model.squashTip(of: squash) == tip.id }
        #expect(laidOut)
        #expect(model.squashTip(of: tip) == nil)
        #expect(model.squashRevision > 0)

        Preference.squashMergesAsMerges.set(false, harness.defaults)
        let unlinked = await eventually { model.squashLinks.isEmpty }
        #expect(unlinked)
    }

    @Test func anAuthorTabShowsOnlyThatAuthorsCommits() async throws {
        let harness = try ModelHarness()
        try harness.repository.importCommits(Self.longHistory)
        let model = harness.model
        let author = GitCommit(
            id: "", parents: [], subject: "", author: "Gita Tests", email: "tests@example.invalid", date: Date())
        model.authorLens = CommitAuthor(author)
        try await harness.open()
        #expect(model.snapshot?.commits.count == HistoryPage.size)
        #expect(model.graphInput(model.snapshot?.commits ?? []).count == HistoryPage.size)
        model.loadMore()
        try await harness.settle { model.snapshot?.commits.count == Self.longHistory }
        #expect(!model.collapsesMerges)

        try harness.repository.write("file.txt", "edited\n")
        model.refresh()
        try await harness.settle { model.snapshot?.changes.count == 1 }
        #expect(model.snapshot?.commits.count == Self.longHistory)
        var laidOut = false
        model.relayoutHistory { laidOut = true }
        #expect(laidOut)
    }
}
