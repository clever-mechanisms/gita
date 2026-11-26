import Foundation
import Testing

@testable import GitaCore

@Suite struct WorkflowCleanupStashManagementTests {
    @Test func allChangesThenPopRestoresIndexAndUntrackedFiles() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("file.txt", "index\n")
        try await repo.git(["add", "file.txt"])
        try repo.write("file.txt", "worktree\n")
        try repo.write("untracked", "new")
        try await repo.service.createStash(.init(message: "  staged and unstaged  "))
        #expect(try await repo.git(["status", "--porcelain"]).text.isEmpty)
        #expect(try await repo.git(["stash", "list"]).text.contains("staged and unstaged\n"))
        let stashCommit = try await repo.oid("stash@{0}")
        let outcome = try await repo.service.popStash(ref: "stash@{0}", expectedCommitID: stashCommit)
        #expect(outcome == .applied)
        #expect(try await repo.git(["show", ":file.txt"]).text == "index\n")
        #expect(try await repo.git(["status", "--porcelain"]).text == "MM file.txt\n?? untracked\n")
        #expect(try await repo.git(["stash", "list"]).text.isEmpty)
    }

    @Test func trackedOnlyKeepsIndexAndDropRemovesOnlyTheStash() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("file.txt", "staged\n")
        try await repo.git(["add", "file.txt"])
        try repo.write("file.txt", "unstaged\n")
        try repo.write("other", "untracked")
        try await repo.service.createStash(.init(scope: .trackedOnly, keepIndex: true))
        #expect(try await repo.git(["status", "--porcelain"]).text == "M  file.txt\n?? other\n")
        #expect(try await repo.git(["show", "stash@{0}:file.txt"]).text == "unstaged\n")
        let stashCommit = try await repo.oid("stash@{0}")
        try await repo.service.dropStash(ref: "stash@{0}", expectedCommitID: stashCommit)
        #expect(try await repo.git(["stash", "list"]).text.isEmpty)
    }

    @Test func stagedOnlyAndBranchFromStash() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("added", "index only")
        try await repo.git(["add", "added"])
        try repo.write("file.txt", "leave behind")
        try await repo.service.createStash(.init(scope: .stagedOnly))
        #expect(try await repo.git(["status", "--porcelain"]).text == " M file.txt\n")
        let stashCommit = try await repo.oid("stash@{0}")
        try await repo.service.createBranchFromStash(
            name: "saved/work", ref: "stash@{0}", expectedCommitID: stashCommit)
        #expect(try await repo.git(["branch", "--show-current"]).text == "saved/work\n")
        #expect(try await repo.git(["show", ":added"]).text == "index only")
        #expect(try await repo.git(["stash", "list"]).text.isEmpty)
    }

    @Test func selectedPathsAreLiteralAndIncludeUntracked() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("*.txt", "literal star")
        try repo.write("extra.txt", "keep me")
        try repo.write("file.txt", "tracked change")
        try await repo.service.createStash(.init(scope: .selectedPaths(["*.txt", "file.txt"])))
        #expect(try await repo.git(["status", "--porcelain"]).text == "?? extra.txt\n")
        #expect(try await repo.git(["show", "stash@{0}^3:*.txt"]).text == "literal star")
        #expect(try await repo.git(["show", "stash@{0}:file.txt"]).text == "tracked change")
    }

    @Test func popConflictKeepsStashAndIndexConflictRetriesWithoutIndex() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("file.txt", "stashed change\n")
        try await repo.service.createStash(.init())
        try repo.write("file.txt", "conflicting commit\n")
        try await repo.commit("Diverge")
        let conflict = try await repo.service.popStash(ref: "stash@{0}")
        guard case .conflictedStashKept(let conflictMessage) = conflict else {
            Issue.record("Expected conflictedStashKept")
            return
        }
        #expect(!conflictMessage.isEmpty)
        #expect(try await !repo.git(["stash", "list"]).text.isEmpty)
        try await repo.git(["reset", "--hard", "HEAD"])
        try await repo.service.dropStash(ref: "stash@{0}")

        try repo.write("file.txt", "staged in stash\n")
        try await repo.git(["add", "file.txt"])
        try await repo.service.createStash(.init(scope: .stagedOnly))
        try repo.write("file.txt", "new staged change\n")
        try await repo.git(["add", "file.txt"])
        let indexOutcome = try await repo.service.popStash(ref: "stash@{0}")
        guard case .indexConflictRetryWithoutIndex(let indexMessage) = indexOutcome else {
            Issue.record("Expected indexConflictRetryWithoutIndex, got \(indexOutcome)")
            return
        }
        #expect(!indexMessage.isEmpty)
        try await repo.git(["reset", "--hard", "HEAD"])
        let retry = try await repo.service.popStash(ref: "stash@{0}", restoreIndex: false)
        #expect(retry == .applied)
    }

    @Test func rejectsStaleExpectedCommitOnStashShift() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try repo.write("file.txt", "first stash\n")
        try await repo.service.createStash(.init(message: "first"))
        let firstID = try await repo.oid("stash@{0}")
        try repo.write("file.txt", "second stash\n")
        try await repo.service.createStash(.init(message: "second"))
        await #expect(throws: GitError.self) {
            _ = try await repo.service.popStash(ref: "stash@{0}", expectedCommitID: firstID)
        }
        await #expect(throws: GitError.self) {
            try await repo.service.dropStash(ref: "stash@{0}", expectedCommitID: firstID)
        }
        await #expect(throws: GitError.self) {
            try await repo.service.createBranchFromStash(
                name: "from-stale", ref: "stash@{0}", expectedCommitID: firstID)
        }
        #expect(try await repo.git(["stash", "list"]).text.contains("second"))
    }

    @Test func invalidRequestsAndEmptyStash() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        await #expect(throws: CommandError.self) { try await repo.service.createStash(.init(message: "a\0b")) }
        await #expect(throws: StashManagementError.emptySelectedPaths) {
            try await repo.service.createStash(.init(scope: .selectedPaths([])))
        }
        await #expect(throws: StashManagementError.keepIndexUnsupportedForStagedOnly) {
            try await repo.service.createStash(.init(scope: .stagedOnly, keepIndex: true))
        }
        for path in [":(glob)*", "../other", "/other", "bad\0name", ""] {
            await #expect(throws: GitError.self) {
                try await repo.service.createStash(.init(scope: .selectedPaths([path])))
            }
        }
        await #expect(throws: StashManagementError.noChangesToStash) { try await repo.service.createStash(.init()) }
        await #expect(throws: GitError.self) { _ = try await repo.service.popStash(ref: "HEAD") }
        await #expect(throws: GitError.self) { try await repo.service.dropStash(ref: "--all") }
        await #expect(throws: GitError.self) { try await repo.service.createBranchFromStash(name: "ok", ref: "bad") }
        await #expect(throws: GitError.self) {
            try await repo.service.createBranchFromStash(name: "--detach", ref: "stash@{0}")
        }
    }
}
