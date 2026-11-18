import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The model's lifecycle enums on their own: each transition, the stale and cancelled ones too.
@Suite("Model lifecycles: provider reads, page reads, relayouts, squash searches and the review")
@MainActor
struct ModelLifecycleValueTests {
    private func commit(_ id: String, _ parents: [String] = []) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "A", date: Date(timeIntervalSince1970: 0))
    }

    @Test func aProviderReadEndsOnlyItselfAndCancelsToIdle() {
        var read = InFlightRead.idle
        #expect(!read.isRunning)
        let endedIdle = read.end(UUID())
        #expect(!endedIdle)
        let id = UUID()
        let task = Task<Void, Never> {}
        read = .running(id, task)
        #expect(read.isRunning)
        #expect(read.task == task)
        let endedOther = read.end(UUID())
        #expect(!endedOther, "a replaced read leaves its successor running")
        #expect(read.isRunning)
        let ended = read.end(id)
        #expect(ended)
        #expect(!read.isRunning)
        let endedTwice = read.end(id)
        #expect(!endedTwice, "it ends once")

        let cancelled = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        read = .running(UUID(), cancelled)
        read.cancel()
        #expect(!read.isRunning)
        #expect(cancelled.isCancelled)
    }

    @Test func aPageReadRunsFailsAndCancelsToIdle() {
        var read = HistoryPageRead.idle
        #expect(!read.isReading && !read.hasFailed)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        read = .reading(task)
        #expect(read.isReading)
        read.cancel()
        #expect(task.isCancelled)
        #expect(!read.isReading && !read.hasFailed)
        read = .failed
        #expect(read.hasFailed && !read.isReading)
        read.cancel()
        #expect(!read.hasFailed)

        var search = HistorySearch()
        search.begin("x", field: .message)
        search.read = .reading(Task {})
        search.invalidate()
        #expect(!search.isSearching, "a stopped model's search is not loading")
        search.read = .failed
        search.begin("y", field: .message)
        #expect(!search.read.hasFailed, "a new query starts without the old failure")

        var focus = BranchFocus()
        focus.reference = GitReference(name: "main", fullName: "refs/heads/main", commit: "a", kind: .branch)
        focus.read = .failed
        focus.discard()
        #expect(!focus.read.hasFailed, "a discarded focus takes its failure along")
        #expect(!focus.isLoading)
    }

    @Test func aSquashSearchKeepsItsKeyUntilCancelled() {
        var search = SquashSearch.none
        #expect(search.key == nil && !isSearching(search))
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        search = .searching(key: "k", task)
        #expect(search.key == "k" && isSearching(search))
        search.cancel()
        #expect(task.isCancelled)
        #expect(search.key == nil)
        search = .found(key: "k")
        #expect(search.key == "k" && !isSearching(search))
        search.cancel()
        #expect(search.key == nil)
    }

    @Test func aNewerRelayoutReplacesTheOlderAndTakesItsCallbacks() {
        var state = HistoryGraphState()
        var calls: [String] = []
        let first = UUID()
        let older = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        state.startRelayout(first, older, then: { calls.append("first") })
        #expect(isRunning(state.relayout))
        let second = UUID()
        state.startRelayout(second, Task {}, then: { calls.append("second") })
        #expect(older.isCancelled)
        let replaced = state.endRelayout(first)
        #expect(!isRunning(replaced), "the replaced relayout never lands")
        #expect(isRunning(state.relayout))
        let ended = state.endRelayout(second)
        #expect(!isRunning(state.relayout))
        guard case .running(_, _, let waiting) = ended else {
            Issue.record("the latest relayout lands")
            return
        }
        waiting.forEach { $0() }
        #expect(calls == ["first", "second"])

        state.startRelayout(UUID(), Task {}, then: nil)
        state.reset()
        #expect(!isRunning(state.relayout))
    }

    @Test func theReviewHoldsOneTargetAndOneItem() {
        var selection = SelectionState()
        #expect(selection.target == .workingTree)
        #expect(selection.commit == nil && selection.stash == nil && selection.base == nil)

        let merge = commit("m", ["a", "b"])
        selection.target = .commit(merge, base: "b")
        #expect(selection.commit == merge && selection.base == "b" && selection.stash == nil)
        // A refresh's newer copy of the same commit keeps the comparison.
        selection.commit = commit("m", ["a", "b"])
        #expect(selection.base == "b")
        selection.item = .treeEntry(path: "y")
        selection.commit = nil
        #expect(selection.target == .workingTree)
        #expect(selection.item == .none, "only a commit has a tree")

        let stash = GitStash(ref: "stash@{0}", subject: "WIP")
        selection.target = .stash(stash)
        #expect(selection.stash == stash && selection.commit == nil && selection.base == nil)

        let file = FileChange(path: "x", indexStatus: "M", worktreeStatus: " ")
        selection.item = .file(file)
        #expect(selection.file == file && selection.treePath == nil && !selection.diffIsBlob)
        selection.item = .treeEntry(path: "y")
        #expect(selection.file == nil && selection.treePath == "y" && selection.diffIsBlob)
        selection.clear()
        #expect(selection.target == .workingTree && selection.item == .none)
    }
}

/// Whether a squash search runs (pattern matching kept out of `#expect`).
@MainActor func isSearching(_ search: SquashSearch) -> Bool {
    if case .searching = search { true } else { false }
}

/// Whether a relayout runs.
@MainActor func isRunning(_ relayout: HistoryRelayout) -> Bool {
    if case .running = relayout { true } else { false }
}
