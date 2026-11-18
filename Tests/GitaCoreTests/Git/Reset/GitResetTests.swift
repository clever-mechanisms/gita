import Foundation
import Testing

@testable import GitaCore

/// Reset to a reviewed commit in a real temporary repository: what each mode keeps, and every guard that refuses a
/// hard reset or a stale review before Git runs.
@Suite(.serialized)
struct GitResetTests {
    private func twoCommits(_ fixture: OperationFixture) async throws -> (first: String, second: String) {
        try fixture.write("file.txt", "one\n")
        let first = try await fixture.commit("First")
        try fixture.write("file.txt", "two\n")
        try fixture.write("added.txt", "added\n")
        let second = try await fixture.commit("Second")
        return (first, second)
    }

    private func status(_ fixture: OperationFixture) async throws -> String {
        try await fixture.git(["status", "--porcelain"]).text
    }

    @Test func previewDescribesTargetHeadBranchAndLocalChanges() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let (first, second) = try await twoCommits(fixture)
        try fixture.write("file.txt", "dirty\n")
        try fixture.write("new.txt", "untracked\n")
        let preview = try await fixture.service.resetPreview(to: first)
        #expect(preview.target.id == first)
        #expect(preview.target.subject == "First")
        #expect(preview.currentHeadID == second)
        #expect(preview.currentBranch == "main")
        #expect(preview.trackedChangeCount == 1)
        #expect(preview.untrackedFileCount == 1)
        #expect(!preview.identity.isEmpty)
        // Reading again without a change gives the same identity; a working-file edit changes it.
        #expect(try await fixture.service.resetPreview(to: first).identity == preview.identity)
        try fixture.write("file.txt", "edited again\n")
        #expect(try await fixture.service.resetPreview(to: first).identity != preview.identity)
    }

    @Test func softMixedAndHardResetMoveHeadAndKeepWhatTheirModePromises() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let (first, _) = try await twoCommits(fixture)
        let service = fixture.service

        try await service.reset(try await service.resetPreview(to: first), mode: .soft)
        #expect(try await fixture.head() == first)
        #expect(try await status(fixture).contains("M  file.txt"), "soft keeps the change staged")

        try await fixture.git(["commit", "-m", "Again"])
        try await service.reset(try await service.resetPreview(to: first), mode: .mixed)
        #expect(try await fixture.head() == first)
        #expect(try await status(fixture).contains(" M file.txt"), "mixed keeps the change unstaged")

        try await fixture.git(["add", "--all"])
        try await fixture.git(["commit", "-m", "Once more"])
        try await service.reset(try await service.resetPreview(to: first), mode: .hard)
        #expect(try await fixture.head() == first)
        #expect(try await status(fixture).isEmpty)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
    }

    @Test func staleReviewIsRefusedWithoutMovingHead() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let (first, second) = try await twoCommits(fixture)
        let preview = try await fixture.service.resetPreview(to: first)
        try fixture.write("file.txt", "changed after the review\n")
        await expectError(ResetError.reviewChanged) {
            try await fixture.service.reset(preview, mode: .mixed)
        }
        #expect(try await fixture.head() == second)
    }

    @Test func hardResetRefusesAnUntrackedFileItWouldOverwrite() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "one\n")
        try fixture.write("later.txt", "tracked at first\n")
        let first = try await fixture.commit("First")
        try await fixture.git(["rm", "--quiet", "later.txt"])
        let second = try await fixture.commit("Second")
        try fixture.write("later.txt", "my untracked notes\n")
        let preview = try await fixture.service.resetPreview(to: first)
        await expectError(ResetError.untrackedOverwritten) {
            try await fixture.service.reset(preview, mode: .hard)
        }
        #expect(try await fixture.head() == second)
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("later.txt"), encoding: .utf8)
                == "my untracked notes\n")
        // A mixed reset does not touch working files, so it is allowed.
        try await fixture.service.reset(preview, mode: .mixed)
        #expect(try await fixture.head() == first)
    }

    @Test func invalidTargetsActiveOperationsAndMissingHeadAreRefused() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        await expectGitError(.invalidReference) { _ = try await fixture.service.resetPreview(to: "main") }
        await expectError(ResetError.noHead) {
            _ = try await fixture.service.resetPreview(to: String(repeating: "a", count: 40))
        }
        let (first, _) = try await twoCommits(fixture)
        await expectError(ResetError.fullCommitID) {
            _ = try await fixture.service.resetPreview(to: String(repeating: "b", count: 40))
        }
        try Data().write(to: fixture.root.appendingPathComponent(".git/BISECT_START"))
        await expectGitError(.operationActive) { _ = try await fixture.service.resetPreview(to: first) }
    }

    @Test func obstructionCoversThePathItsAncestorsAndItsDescendants() {
        let protected: Set<String> = ["a/b/c.txt", "d", "e/f"]
        let sorted = protected.sorted()
        #expect(HardResetSafety.isObstructed("d", protected: protected, sorted: sorted))
        #expect(HardResetSafety.isObstructed("d/inside.txt", protected: protected, sorted: sorted))
        #expect(HardResetSafety.isObstructed("a", protected: protected, sorted: sorted))
        #expect(HardResetSafety.isObstructed("a/b", protected: protected, sorted: sorted))
        #expect(!HardResetSafety.isObstructed("a/bc", protected: protected, sorted: sorted))
        #expect(!HardResetSafety.isObstructed("e", protected: ["e/f"], sorted: []))
        #expect(!HardResetSafety.isObstructed("z", protected: protected, sorted: sorted))
    }

    @Test func hardResetRefusesDirtySubmodulesAndSubmoduleTransitions() throws {
        let commit = GitCommit(
            id: String(repeating: "c", count: 40), parents: [], subject: "S", author: "A",
            date: Date(timeIntervalSince1970: 0))
        let preview = GitResetPreview(
            target: commit, currentHeadID: commit.id, currentBranch: nil, trackedChangeCount: 0,
            untrackedFileCount: 0, identity: "")
        func review(
            index: [String: TreeEntries.Entry] = [:], target: [String: TreeEntries.Entry] = [:], status: String = ""
        ) -> HardResetSafety {
            HardResetSafety(
                review: ResetReview(
                    preview: preview, options: [], index: index, target: target, otherPaths: [],
                    status: Data(status.utf8),
                    caseSensitive: false))
        }
        let module = TreeEntries.Entry(mode: .submodule)
        let file = TreeEntries.Entry(mode: .regular)
        #expect(throws: Never.self) { try review(index: ["lib": module], target: ["lib": module]).check() }
        #expect(throws: ResetError.submoduleChanges) {
            try review(
                index: ["lib": module], target: ["lib": module], status: "1 .M SC.. 160000 160000 160000 a b lib"
            )
            .check()
        }
        #expect(throws: ResetError.submodulePathsChange) {
            try review(index: ["lib": module], target: ["lib": file]).check()
        }
        #expect(throws: ResetError.submodulePathsChange) { try review(target: ["lib": module]).check() }
        // Names compare case-folded and normalized on a case-insensitive volume.
        #expect(review().filesystemName("Caf\u{0065}\u{0301}.TXT") == "café.txt")
    }
}
