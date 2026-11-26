import Foundation
import Testing

@testable import GitaCore

@Suite struct WorkflowCleanupBranchStackTests {
    private func topology(_ tips: [String], base: String = "root") -> BranchStackTopologyInput {
        func ref(_ name: String, _ commit: String) -> GitReference {
            GitReference(name: name, fullName: "refs/heads/" + name, commit: commit, kind: .branch)
        }
        let parents = ["new": "root", "c": "b", "other": "a", "b": "a", "a": "root"]
        let commits = ["new", "c", "other", "b", "a", "root"].map {
            GitCommit(id: $0, parents: parents[$0].map { [$0] } ?? [], subject: $0, author: "test", date: .distantPast)
        }
        return BranchStackTopologyInput(branches: tips.map { ref($0, $0) }, base: ref("main", base), commits: commits)
    }

    @Test func nearestAncestorsAndIndependentLeaves() throws {
        let stacks = BranchStackDetector.detect(topology(["other", "c", "a", "b"]))
        #expect(stacks.map(\.topBranch) == ["c", "other"])
        let chain = try #require(stacks.first)
        #expect(chain.layers.map(\.branchName) == ["a", "b", "c"])
        #expect(chain.layers.map(\.depth) == [1, 2, 3])
        #expect(chain.layers.map(\.aheadOfBase) == [1, 2, 3])
        #expect(chain.layers.map(\.commitSubjects) == [["a"], ["b"], ["c"]])
        #expect(!chain.needsRestack && chain.totalCommits == 3)
        #expect(stacks.last?.layers.map(\.branchName) == ["a", "other"])
        let moved = try #require(BranchStackDetector.detect(topology(["a", "c"], base: "new")).first)
        #expect(moved.needsRestack && moved.baseBehindCount == 1)
        #expect(moved.layers.map(\.commitsFromParent) == [1, 2])
        #expect(BranchStackDetector.detect(topology([])).isEmpty)
        #expect(BranchStackDetector.detect(topology(["a"])).isEmpty)
        #expect(BranchStackDetector.detect(topology(["a"]), includeSingleLayerBranches: true).count == 1)
    }

    private func makeChain(_ repo: ReferenceFixture, conflict: Bool = false) async throws -> BranchStack {
        try await repo.git(["switch", "-c", "feat-a"])
        try repo.write(conflict ? "file.txt" : "first.txt", "first\n")
        try await repo.commit("First layer")
        try await repo.git(["switch", "-c", "feat-b"])
        try repo.write("second.txt", "second\n")
        try await repo.commit("Second layer")
        try await repo.git(["switch", "main"])
        try repo.write("file.txt", "advanced\n")
        try await repo.commit("Advance base")
        return try #require(try await repo.service.detectBranchStacks().first)
    }

    @Test func updateRefsMovesIntermediateBranchesAndRestoresOriginalBranch() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let stack = try await makeChain(repo)
        #expect(stack.needsRestack && stack.layers.map(\.branchName) == ["feat-a", "feat-b"])
        let preview = try await repo.service.previewStackRestack(stack: stack)
        #expect(preview.ontoCommitID == stack.baseCommitID)
        #expect(preview.currentBranch == "main")
        #expect(preview.commitsToReplay.map(\.subject) == ["Second layer", "First layer"])
        #expect(preview.branchesToUpdate == ["feat-a", "feat-b"] && preview.blockedByWorktreePaths.isEmpty)
        #expect(preview.forkedSiblingBranches.isEmpty)
        let result = try await repo.service.restackBranchStack(preview)
        guard case .completed = result.outcome else {
            Issue.record("Expected completed rebase")
            return
        }
        #expect(result.updatedBranches == ["feat-a", "feat-b"])
        #expect(try await repo.git(["branch", "--show-current"]).text == "main\n")
        #expect(try await repo.oid("feat-a^") == stack.baseCommitID)
        let newFirst = try await repo.oid("feat-a")
        #expect(try await repo.oid("feat-b^") == newFirst)
        #expect(try await repo.oid("feat-b") != stack.layers.last?.commitID)
        #expect(try await repo.git(["show", "feat-a:first.txt"]).text == "first\n")
        #expect(try await repo.git(["show", "feat-b:second.txt"]).text == "second\n")
        #expect(try await repo.git(["show", "feat-b:file.txt"]).text == "advanced\n")
        #expect(try await repo.service.detectBranchStacks().first?.needsRestack == false)
    }

    @Test func detectsForkedSiblingBranchesInPreview() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        _ = try await makeChain(repo)
        try await repo.git(["switch", "-c", "feat-side", "feat-a"])
        try repo.write("side.txt", "sibling\n")
        try await repo.commit("Sibling branch work")
        try await repo.git(["switch", "main"])
        let stacks = try await repo.service.detectBranchStacks()
        let primary = try #require(stacks.first { $0.topBranch == "feat-b" })
        let preview = try await repo.service.previewStackRestack(stack: primary)
        #expect(preview.forkedSiblingBranches == ["feat-side"])
    }

    @Test func remoteDefaultWithoutALocalCounterpartAnchorsBothWorkflows() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let original = try await makeChain(repo)
        try await repo.git(["update-ref", "refs/remotes/origin/trunk", original.baseCommitID])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"])
        try await repo.git(["branch", "merged-at-origin"])
        try repo.write("local-only", "local")
        try await repo.commit("Local main advanced")
        try await repo.git(["branch", "only-in-main"])
        let report = try await repo.service.scanCleanupCandidates()
        #expect(report.defaultBranch == "origin/trunk")
        #expect(report.branches.map(\.name) == ["merged-at-origin"])
        let stack = try #require(try await repo.service.detectBranchStacks().first)
        #expect(stack.baseFullName == "refs/remotes/origin/trunk")
        let preview = try await repo.service.previewStackRestack(stack: stack)
        #expect(preview.ontoCommitID == original.baseCommitID)
        let result = try await repo.service.restackBranchStack(preview)
        #expect(result.updatedBranches == ["feat-a", "feat-b"])
        #expect(try await repo.oid("feat-a^") == original.baseCommitID)
    }

    @Test func conflictReturnsResumableOperationState() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let stack = try await makeChain(repo, conflict: true)
        let preview = try await repo.service.previewStackRestack(stack: stack)
        let result = try await repo.service.restackBranchStack(preview)
        guard case .stopped(let state, let message) = result.outcome else {
            Issue.record("Expected a stopped rebase")
            return
        }
        #expect(state.kind == .rebase && !message.isEmpty)
        #expect(result.updatedBranches.isEmpty)
        #expect(try await repo.service.operationState() == state)
        _ = try await repo.service.abortOperation(expected: state)
        #expect(try await repo.oid("HEAD") == stack.layers.last?.commitID)
    }

    @Test func rechecksWorktreesAndAdditionalRefsBeforeSwitching() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let stack = try await makeChain(repo)
        let original = try await repo.service.previewStackRestack(stack: stack)
        try await repo.git(["branch", "alias", "feat-a"])
        await #expect(throws: GitError.self) { try await repo.service.restackBranchStack(original) }
        let path = repo.container.appendingPathComponent("another checkout")
        try await repo.git(["worktree", "add", path.path, "feat-a"])
        let preview = try await repo.service.previewStackRestack(stack: stack)
        #expect(preview.branchesToUpdate.contains("alias"))
        #expect(preview.blockedByWorktreePaths == [path.resolvingSymlinksInPath().path])
        await #expect(throws: BranchStackError.self) { try await repo.service.restackBranchStack(preview) }
        #expect(try await repo.git(["branch", "--show-current"]).text == "main\n")
    }
}
