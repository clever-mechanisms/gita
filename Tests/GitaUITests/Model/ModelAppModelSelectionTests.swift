import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel review pane: commits, merges, trees, stashes and the working tree")
@MainActor
struct ModelAppModelSelectionTests {
    /// main: Base → Main change → Merge feature; feature: Feature change.
    private func mergeHarness() async throws -> ModelHarness {
        let harness = try ModelHarness()
        let repository = harness.repository
        try repository.commit("base.txt", "base\n", message: "Base")
        try repository.git("checkout", "-q", "-b", "feature")
        try repository.commit("feature.txt", "feature\n", message: "Feature change")
        try repository.git("checkout", "-q", "main")
        try repository.commit("main.txt", "main\n", message: "Main change")
        try repository.merge("feature", message: "Merge feature")
        try await harness.open()
        try await harness.settle { !harness.model.isDiffLoading && harness.model.selectedFile != nil }
        return harness
    }

    @Test func aMergeIsComparedWithEitherParent() async throws {
        let harness = try await mergeHarness()
        let model = harness.model
        let merge = try harness.commit("Merge feature")
        #expect(model.selectedCommit?.id == merge.id)
        #expect(model.files.map(\.path) == ["feature.txt"])

        model.compareWithParent(1)
        try await harness.settle { model.comparisonBase == merge.parents[1] && !model.isDiffLoading }
        #expect(model.files.map(\.path) == ["main.txt"])
        #expect(model.diff.contains("+main"))

        model.compareWithParent(0)
        try await harness.settle { model.comparisonBase == nil && !model.isDiffLoading }
        #expect(model.files.map(\.path) == ["feature.txt"])

        model.compareWithParent(7) // no such parent: nothing changes
        #expect(model.comparisonBase == nil)
    }

    /// The review is one target showing one item: a merge's comparison is part of its commit, a file and a tree
    /// entry replace each other, and deselecting goes back to the working tree with nothing compared.
    @Test func theReviewIsOneTargetShowingOneItem() async throws {
        let harness = try await mergeHarness()
        let model = harness.model
        let merge = try harness.commit("Merge feature")
        model.compareWithParent(1)
        try await harness.settle { model.comparisonBase == merge.parents[1] && !model.isDiffLoading }
        #expect(model.selection.target == .commit(merge, base: merge.parents[1]))
        #expect(model.selectedFile?.path == "main.txt")

        model.reviewTree(true)
        try await harness.settle { model.isTreeReview && model.commitDetails != nil && !model.isDiffLoading }
        #expect(model.selection.target == .commit(merge, base: merge.parents[1]))
        #expect(model.selection.item == .none)
        model.selectTreeEntry(TreeEntry(path: "base.txt", kind: "blob", objectID: "0"))
        #expect(model.selection.item == .treeEntry(path: "base.txt"))
        #expect(model.diffIsBlob)
        #expect(model.selectedFile == nil)
        try await harness.settle { !model.isDiffLoading }

        let file = try #require(model.files.first)
        model.selectFile(file)
        #expect(model.selection.item == .file(file))
        #expect(!model.diffIsBlob)
        #expect(model.selectedTreePath == nil)
        try await harness.settle { !model.isDiffLoading }
        model.reviewTree(false)
        try await harness.settle { !model.isTreeReview && !model.isDiffLoading }

        model.deselectCommit()
        #expect(model.selection.target == .workingTree)
        #expect(model.selection.item == .none)
        #expect(model.comparisonBase == nil)
    }

    @Test func treeReviewShowsFilesAndSubmoduleEntries() async throws {
        let harness = try await mergeHarness()
        let model = harness.model
        model.reviewTree(true)
        try await harness.settle { model.isTreeReview && model.commitDetails != nil && !model.isDiffLoading }
        #expect(model.selectedFile == nil)

        model.selectTreeEntry(TreeEntry(path: "base.txt", kind: "blob", objectID: "0"))
        try await harness.settle { !model.isDiffLoading && model.diff == "base\n" }
        #expect(model.selectedTreePath == "base.txt")
        #expect(model.diffIsBlob)

        model.selectTreeEntry(TreeEntry(path: "vendor", kind: "commit", objectID: "abc123"))
        try await harness.settle { !model.isDiffLoading && model.diff == "Submodule commit abc123" }

        model.selectTreeEntry(TreeEntry(path: "missing.txt", kind: "blob", objectID: "0"))
        try await harness.settle { !model.isDiffLoading && model.diff != "Submodule commit abc123" }
        #expect(model.events.first?.title == String(localized: "Diff failed"))

        model.reviewTree(false)
        try await harness.settle { !model.isTreeReview && model.selectedFile != nil && !model.isDiffLoading }
    }

    @Test func treeEntriesNeedATreeReview() async throws {
        let harness = try await mergeHarness()
        harness.model.selectTreeEntry(TreeEntry(path: "base.txt", kind: "blob", objectID: "0"))
        #expect(harness.model.selectedTreePath == nil)
    }

    @Test func aFailedCommitReadShowsTheErrorAsTheDiff() async throws {
        let harness = try await mergeHarness()
        let model = harness.model
        let missing = GitCommit(
            id: String(repeating: "0", count: 40), parents: [], subject: "Gone", author: "A", date: Date())
        model.select(missing)
        try await harness.settle { !model.isDiffLoading }
        #expect(!model.diff.isEmpty)
        #expect(model.events.first?.failed == true)
    }

    @Test func aStashShowsItsFiles() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try harness.repository.write("a.txt", "stashed\n")
        try harness.repository.git("stash", "push", "-q", "-m", "Work in progress")
        try await harness.open()
        let model = harness.model
        let stash = try #require(model.snapshot?.stashes.first)
        model.section = .changes
        model.selectStash(stash)
        #expect(model.section == .history)
        try await harness.settle { model.selectedStash == stash && model.diffPath == "a.txt" && !model.isDiffLoading }
        #expect(model.diff.contains("+stashed"))
        #expect(model.selection.target == .stash(stash))
        #expect(model.selectedCommit == nil)

        // A refresh keeps the stash selected while it still exists.
        try harness.repository.write("b.txt", "b\n")
        model.refresh()
        try await harness.settle { model.snapshot?.changes.count == 1 }
        #expect(model.selectedStash == stash)

        // A commit replaces the stash as the review.
        let first = try harness.commit("First")
        model.select(first)
        #expect(model.selection.target == .commit(first, base: nil))
        #expect(model.selectedStash == nil)
        try await harness.settle { !model.isDiffLoading }
    }

    @Test func theChangesPageFollowsTheWorkingTree() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try harness.repository.write("a.txt", "one\n")
        try await harness.open()
        let model = harness.model
        model.section = .changes
        try await harness.settle { model.diff.contains("+one") && !model.isDiffLoading }
        let revision = model.filesRevision

        // Another file appears: the list is rebuilt, the shown file stays and its diff is read again.
        try harness.repository.write("a.txt", "two\n")
        try harness.repository.write("b.txt", "b\n")
        model.refresh()
        try await harness.settle { model.files.count == 2 && model.diff.contains("+two") && !model.isDiffLoading }
        #expect(model.filesRevision != revision)
        #expect(model.selectedFile?.path == "a.txt")
        model.selectFile(try #require(model.files.last))
        try await harness.settle { model.diffPath == "b.txt" && !model.isDiffLoading }
        #expect(model.diff.contains("+b"))

        // Everything committed away: nothing left to show.
        try harness.repository.git("add", "-A")
        try harness.repository.git("commit", "-q", "-m", "Second")
        model.refresh()
        try await harness.settle { model.files.isEmpty }
        #expect(model.selectedFile == nil)
        #expect(model.diff.isEmpty)
        #expect(model.diffPath == nil)
    }

    @Test func aNewCommitKeepsTheSelectedCommitsReview() async throws {
        let harness = try await mergeHarness()
        let model = harness.model
        let base = try harness.commit("Base")
        model.select(base)
        try await harness.settle { model.selectedCommit == base && model.commitDetails != nil && !model.isDiffLoading }
        try harness.repository.commit("later.txt", "later\n", message: "Later")
        model.refresh()
        try await harness.settle { model.snapshot?.commits.first?.subject == "Later" }
        #expect(model.selectedCommit?.id == base.id)
        #expect(model.files.map(\.path) == ["base.txt"])
    }
}
