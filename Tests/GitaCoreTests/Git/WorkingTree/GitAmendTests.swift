import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitAmendTests {
    @Test func aRepositoryWithNoCommitCannotBeAmended() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        #expect(try await fixture.service.amendCommit() == nil)
    }

    @Test func amendRewritesTheMessageAndKeepsTheParentTreeAndAuthor() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "one\n")
        let original = try await fixture.commit("Initial commit\n\nNotes")
        let before = try await fixture.service.commitDetails(ref: "HEAD")
        let source = try await fixture.service.amendCommit()
        let loaded = try #require(source)
        #expect(loaded.id == original)
        #expect(loaded.isPublished == false)
        #expect(loaded.isDetached == false)
        #expect(loaded.message == before.message)

        try await fixture.service.commit(message: "Initial commit\n\nNotes kept", amending: original)
        let after = try await fixture.service.commitDetails(ref: "HEAD")
        #expect(after.commit.id != original)
        #expect(after.commit.parents == before.commit.parents)
        #expect(after.commit.author == before.commit.author)
        #expect(after.message == "Initial commit\n\nNotes kept\n")
        #expect(try await fixture.git(["show", "HEAD:README.md"]).text == "one\n")
    }

    @Test func amendIncludesStagedChanges() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "one\n")
        let original = try await fixture.commit("Initial commit")
        try fixture.write("README.md", "two\n")
        try await fixture.service.stage(paths: ["README.md"])
        try await fixture.service.commit(message: "Initial commit", amending: original)
        #expect(try await fixture.git(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .newlines) == "1")
        #expect(try await fixture.git(["show", "HEAD:README.md"]).text == "two\n")
    }

    @Test func amendLoadsCommitChangesAndCanUnstageFilesAndHunks() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let baseline = (1...35).map { "Line \($0)\n" }.joined()
        try fixture.write("a.txt", baseline)
        let first = try await fixture.commit("First")
        let rootSource = try #require(try await fixture.service.amendCommit())
        #expect(!rootSource.baseTree.isEmpty)
        #expect(try await fixture.service.stagedChanges(against: rootSource.baseTree).map(\.path) == ["a.txt"])

        let edited =
            baseline
            .replacingOccurrences(of: "Line 2\n", with: "Changed 2\n")
            .replacingOccurrences(of: "Line 30\n", with: "Changed 30\n")
        try fixture.write("a.txt", edited)
        try fixture.write("extra.txt", "extra\n")
        let second = try await fixture.commit("Second")
        let source = try #require(try await fixture.service.amendCommit())
        #expect(source.baseTree == first)
        #expect(
            try await fixture.service.stagedChanges(against: source.baseTree).map(\.path).sorted() == [
                "a.txt", "extra.txt",
            ])

        // Unstage extra.txt and hunk 0 of a.txt relative to parent, then amend.
        try await fixture.service.unstage(paths: ["extra.txt"], source: source.baseTree)
        let diff = try await fixture.service.diff(path: "a.txt", staged: true, stagedBase: source.baseTree)
        try await fixture.service.applyHunk(
            path: "a.txt", staged: true, expectedDiff: diff, hunkIndex: 0, stagedBase: source.baseTree)
        #expect(try await fixture.service.stagedChanges(against: source.baseTree).map(\.path) == ["a.txt"])

        // Restoring staged back to HEAD puts everything back without touching the working tree.
        try await fixture.service.restoreStagedToHead(paths: ["extra.txt", "a.txt", "missing.txt"])
        #expect(
            try await fixture.service.stagedChanges(against: source.baseTree).map(\.path).sorted() == [
                "a.txt", "extra.txt",
            ])

        // Unstaging everything allows amending to an empty commit when requested.
        try await fixture.service.unstage(paths: ["extra.txt", "a.txt"], source: source.baseTree)
        #expect(try await fixture.service.stagedChanges(against: source.baseTree).isEmpty)
        try await fixture.service.commit(message: "Second, emptied", amending: second)
        #expect(try await fixture.service.changedFiles(commit: "HEAD").isEmpty)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("extra.txt"), encoding: .utf8) == "extra\n")
    }

    @Test func amendRefusesAMovedHeadAnEmptyMessageAndABadIdentity() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "one\n")
        let original = try await fixture.commit("Initial commit")
        try fixture.write("README.md", "two\n")
        _ = try await fixture.commit("Second")
        await expectGitError(.staleReference) { try await fixture.service.commit(message: "Nope", amending: original) }
        await expectGitError(.emptyMessage) { try await fixture.service.commit(message: "  \n", amending: original) }
        await expectGitError(.invalidReference) {
            try await fixture.service.commit(message: "Nope", amending: "not-a-commit")
        }
    }

    @Test func aCommitAlreadyOnItsUpstreamIsPublishedAndADetachedHeadIsNot() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "one\n")
        _ = try await fixture.commit("Initial commit")
        let origin = fixture.container.appendingPathComponent("origin.git")
        try await fixture.git(["init", "--bare", "--template=", origin.path])
        try await fixture.git(["remote", "add", "origin", origin.path])
        try await fixture.git(["push", "--set-upstream", "origin", "HEAD"])
        let published = try #require(try await fixture.service.amendCommit())
        #expect(published.isPublished)
        #expect(!published.isDetached)

        try fixture.write("README.md", "two\n")
        _ = try await fixture.commit("Second")
        let ahead = try #require(try await fixture.service.amendCommit())
        #expect(!ahead.isPublished)

        try await fixture.git(["switch", "--detach"])
        let detached = try #require(try await fixture.service.amendCommit())
        #expect(detached.isDetached)
        #expect(!detached.isPublished)
        #expect(detached.id == ahead.id)
    }

    @Test func amendIsRefusedWhileAnOperationIsInProgress() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        _ = try await fixture.diverge()
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let head = try await fixture.head()
        await expectGitError(.operationActive) {
            try await fixture.service.commit(message: "During a merge", amending: head)
        }
    }
}
