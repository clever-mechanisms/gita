import Foundation
import Testing

@testable import GitaCore

@Suite struct SpeculativeGitServiceTests {
    @Test func reorderIndependentCommitsAndDetectEmpty() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("base", "base")
        let base = try await repo.commit("Base")
        try repo.write("one", "one")
        let one = try await repo.commit("One")
        try repo.write("two", "two")
        let two = try await repo.commit("Two")
        let service = SpeculativeGitService(gitService: repo.service)
        let result = try await service.simulateRebase(
            onto: base,
            steps: [
                .init(commitID: two), .init(commitID: one, action: .reword), .init(commitID: one),
            ])
        #expect(result.steps.map(\.outcome) == [.clean, .clean, .empty])
        let expectedTree = try await repo.git(["rev-parse", "HEAD^{tree}"])
        #expect(result.finalTreeID == GitOutput.withoutTerminalLF(expectedTree.text))
        let root = try await service.checkCherryPick(commit: base, onto: base)
        #expect(root.outcome == .empty)
    }

    @Test func conflictedReorderAndDrop() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let path = "file with\nnewline"
        try repo.write(path, "base\n")
        let base = try await repo.commit("Base")
        try repo.write(path, "one\n")
        let one = try await repo.commit("One")
        try repo.write(path, "two\n")
        let two = try await repo.commit("Two")
        let service = SpeculativeGitService(gitService: repo.service)
        let steps = [GitRebaseStep(commitID: two), GitRebaseStep(commitID: one)]
        let result = try await service.simulateRebase(onto: base, steps: steps)
        #expect(result.steps.first?.outcome.conflictingFiles == [path])
        #expect(result.overallRisk == .conflict)
        #expect(result.conflictingFiles == [path])
        #expect(result.steps.count == 2)
        let tree = try #require(result.steps.first?.resultingTreeID)
        let preview = try await service.previewConflictedFile(treeID: tree, path: path)
        #expect(preview.excerpt.contains("<<<<<<<"))
        let short = try await service.previewConflictedFile(treeID: tree, path: path, maxBytes: 8)
        #expect(short.truncated && short.totalByteCount == preview.excerpt.utf8.count)
        #expect(short.excerpt == String(preview.excerpt.prefix(8)))
        let dropped = try await service.simulateRebase(
            onto: base, steps: [.init(commitID: two, action: .drop), steps[1]])
        #expect(dropped.steps.map(\.outcome) == [.dropped, .clean])
    }

    @Test func pairwiseAndCherryPickPreserveDirtyIndexAndFiles() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let tips = try await repo.diverge()
        try repo.write("staged", "index\n")
        try await repo.git(["add", "staged"])
        try repo.write("staged", "working copy\n")
        let status = try await repo.git(["--no-optional-locks", "status", "--porcelain"]).stdout
        let indexURL = repo.root.appendingPathComponent(".git/index")
        let index = try Data(contentsOf: indexURL)
        let service = SpeculativeGitService(gitService: repo.service)
        let clean = try await service.checkPairwiseMerge(ours: "HEAD^", theirs: "incoming")
        guard case .clean = clean.outcome else {
            Issue.record("Expected a clean merge")
            return
        }
        let merge = try await service.checkPairwiseMerge(ours: "HEAD", theirs: "incoming")
        guard case .conflict(_, let files, let details) = merge.outcome else {
            Issue.record("Expected conflict")
            return
        }
        #expect(files == ["file.txt"] && details.contains("CONFLICT"))
        let cherry = try await service.checkCherryPick(commit: tips.incoming)
        #expect(cherry.outcome.conflictingFiles == ["file.txt"])
        #expect(try await service.checkCherryPick(commit: tips.incoming, onto: "HEAD^").outcome == .clean)
        #expect(try Data(contentsOf: indexURL) == index)
        #expect(try await repo.git(["--no-optional-locks", "status", "--porcelain"]).stdout == status)
        #expect(try String(contentsOf: repo.root.appendingPathComponent("staged"), encoding: .utf8) == "working copy\n")
    }

    @Test func stashPreflightAndUnsupportedMergeCommit() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let tips = try await repo.diverge()
        try repo.write("file.txt", "stash\n")
        try await repo.git(["stash", "push", "-m", "simulation"])
        try repo.write("other", "dirty")
        let before = try await repo.git(["--no-optional-locks", "status", "--porcelain"]).stdout
        let indexURL = repo.root.appendingPathComponent(".git/index")
        let index = try Data(contentsOf: indexURL)
        let service = SpeculativeGitService(gitService: repo.service)
        #expect(try await service.checkStashApply(stashRef: "stash@{0}").outcome == .clean)
        let conflict = try await service.checkStashApply(stashRef: "stash@{0}", onto: tips.incoming)
        #expect(conflict.outcome.conflictingFiles == ["file.txt"])
        let unsupported = try await service.simulateRebase(onto: tips.current, steps: [.init(commitID: "refs/stash")])
        guard case .unsupported = unsupported.steps.first?.outcome else {
            Issue.record("Expected unsupported")
            return
        }
        #expect(unsupported.overallRisk == .warning)
        #expect(try await repo.git(["--no-optional-locks", "status", "--porcelain"]).stdout == before)
        #expect(try Data(contentsOf: indexURL) == index)
    }

    @Test func cacheEvictsLeastRecentlyUsedAndFingerprintsAreStable() {
        var cache = SpeculativeLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        #expect(cache.value(for: "a") == 1)
        cache.insert(3, for: "c")
        #expect(cache.count == 2 && cache.value(for: "b") == nil)
        let steps = [GitRebaseStep(commitID: "abc")]
        let first = PlanFingerprint.hash(baseTree: "base", steps: steps)
        #expect(first.count == 64 && first == PlanFingerprint.hash(baseTree: "base", steps: steps))
        #expect(first != PlanFingerprint.hash(baseTree: "base", steps: [.init(commitID: "abc", action: .drop)]))
    }
}
