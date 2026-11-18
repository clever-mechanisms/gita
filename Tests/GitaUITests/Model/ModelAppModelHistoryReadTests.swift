import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The history list's reads: a search's and a branch focus's pages (`HistoryPageRead`), the relayouts of a folded
/// history (`HistoryRelayout`) and the squash-merge search (`SquashSearch`).
@Suite("AppModel history reads: pages per list, the latest relayout, squash searches")
@MainActor
struct ModelAppModelHistoryReadTests {
    /// main: First, with a `feature` branch at it.
    private func branchHarness() async throws -> ModelHarness {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try harness.repository.git("branch", "feature")
        try await harness.open()
        return harness
    }

    private static let gone = GitReference(
        name: "gone", fullName: "refs/heads/gone", commit: String(repeating: "0", count: 40), kind: .branch)

    /// A search reads its pages and ends idle; stopping the model mid-search leaves nothing "loading".
    @Test func aSearchPageReadEndsIdleHoweverItEnds() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.searchHistory("First", field: .message)
        #expect(model.search.isSearching)
        #expect(model.displayedHistoryIsLoading)
        #expect(await eventually { !model.search.isSearching })
        #expect(!model.search.read.isReading && !model.search.read.hasFailed)
        #expect(model.displayedCommits.map(\.subject) == ["First"])
        #expect(!model.historyPageFailed)

        model.searchHistory("First", field: .message)
        model.stop()
        #expect(!model.search.isSearching)
        #expect(!model.displayedHistoryIsLoading)
    }

    /// A branch focus's failed page is its own: the focus ending another way than Show All (here the branch filters
    /// re-scoping the history) takes it along, and the whole history shows no Retry.
    @Test func aDiscardedFocusTakesItsFailureAlong() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.focusHistory(on: Self.gone)
        #expect(model.focus.isLoading)
        try await harness.settle { model.historyPageFailed && !model.displayedHistoryIsLoading }
        #expect(model.focus.read.hasFailed)
        #expect(!model.allHistoryPageFailed)

        let feature = try #require(model.snapshot?.references.first { $0.fullName == "refs/heads/feature" })
        model.toggleBranchFilter(.hide, feature)
        #expect(model.focusedReference == nil)
        #expect(!model.historyPageFailed)
        try await harness.settle()
    }

    /// The whole history's failure survives a search, and a search's failure is the search's alone.
    @Test func eachListShowsItsOwnFailure() async throws {
        let harness = try await branchHarness()
        let model = harness.model
        model.allHistoryPageFailed = true
        #expect(model.historyPageFailed)
        model.focusHistory(on: Self.gone) // a new history: the earlier failure is cleared, as before
        #expect(!model.allHistoryPageFailed)
        try await harness.settle { model.historyPageFailed && !model.displayedHistoryIsLoading }

        model.search.read = .failed
        model.search.query = "x"
        #expect(model.historyMode.isSearch)
        #expect(model.historyPageFailed)
        model.search.read = .idle
        #expect(!model.historyPageFailed)
        model.searchHistory("", field: .message)
        model.showAllHistory()
        #expect(!model.historyPageFailed)
    }

    /// main: Base → Main change → Merge feature (folded); feature: Feature change.
    private func mergedHarness() async throws -> ModelHarness {
        let harness = try ModelHarness()
        let repository = harness.repository
        try repository.commit("base.txt", "base\n", message: "Base")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.commit("feature.txt", "feature\n", message: "Feature change")
        try repository.git("checkout", "-q", "main")
        try repository.commit("main.txt", "main\n", message: "Main change")
        try repository.merge("feature", message: "Merge feature")
        harness.defaults.set(true, forKey: Preference.collapsesMergedCommits.rawValue)
        try await harness.open()
        return harness
    }

    /// Expanding then folding a merge quickly ends folded whichever layout finishes first: only the latest lands.
    /// Repeated, since the two layouts race.
    @Test func expandingThenFoldingQuicklyEndsFolded() async throws {
        let harness = try await mergedHarness()
        let model = harness.model
        let merge = try harness.commit("Merge feature")
        let inner = try harness.commit("Feature change")
        for _ in 0..<40 {
            let revision = model.squashRevision
            model.expandMerge(merge.id)
            model.collapseMerge(merge.id)
            #expect(isRunning(model.graphState.relayout))
            #expect(await eventually { !isRunning(model.graphState.relayout) })
            #expect(model.squashRevision == revision + 1, "the replaced layout never lands")
            #expect(!model.isMergeExpanded(merge.id))
            #expect(model.collapsedMerge(hiding: inner.id) == merge.id)
        }
    }

    /// A relayout replaced by a newer one still runs its callback, once the newer layout is in place.
    @Test func aReplacedRelayoutsCallbackRunsWithTheNewerLayout() async throws {
        let harness = try await mergedHarness()
        let model = harness.model
        let merge = try harness.commit("Merge feature")
        let inner = try harness.commit("Feature change")
        var calls: [Bool] = []
        model.reveal(inner.id) { calls.append(model.isMergeExpanded(merge.id)) }
        model.relayoutHistory { calls.append(model.isMergeExpanded(merge.id)) }
        #expect(await eventually { calls.count == 2 })
        #expect(calls == [true, true])
        #expect(model.collapsedMerge(hiding: inner.id) == nil)

        model.collapseMerge(merge.id)
        model.stop() // a stopped model lays nothing out
        #expect(!isRunning(model.graphState.relayout))
    }

    /// A squash search that fails keeps the links shown and forgets its references, so the next update searches
    /// again instead of trusting the failed result.
    @Test func aFailedSquashSearchIsTriedAgain() async throws {
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
        #expect(await eventually { !model.squashLinks.isEmpty && !isSearching(model.graphState.squashSearch) })
        let links = model.squashLinks
        let key = try #require(model.graphState.squashSearch.key)
        model.updateSquashLinks() // the same references: nothing to search
        #expect(!isSearching(model.graphState.squashSearch))

        let service = model.service
        model.graphState.cancelSquashSearch()
        model.service = GitService(root: harness.url.appendingPathComponent("missing"))
        model.updateSquashLinks()
        #expect(model.graphState.squashSearch.key == key)
        #expect(await eventually { !isSearching(model.graphState.squashSearch) })
        #expect(model.graphState.squashSearch.key == nil)
        #expect(model.squashLinks == links)

        model.service = service
        model.updateSquashLinks()
        #expect(isSearching(model.graphState.squashSearch))
        #expect(await eventually { !isSearching(model.graphState.squashSearch) })
        #expect(model.graphState.squashSearch.key == key)
        #expect(model.squashLinks == links)
    }
}
