import Foundation
import Testing

@testable import GitaCore

@Suite struct CommitBucketTests {
    @Test func loadAndCommitFailuresHaveDistinctRecovery() {
        let load = CommitBucketState.failed(message: "Read failed", canRetryCommit: false)
        #expect(load != .failed(message: "Read failed", canRetryCommit: true))
    }

    private func lines(early: String = "2", late: String = "33") -> String {
        (1...40).map { line in
            switch line {
            case 2: early
            case 33: late
            default: String(line)
            }
        }.joined(separator: "\n") + "\n"
    }

    private func dirtyPlan(_ repo: OperationFixture) async throws -> CommitBucketPlan {
        try repo.write("tracked", lines())
        try repo.write("leftover", "before\n")
        try await repo.commit("Base")
        try repo.write("tracked", lines(early: "early", late: "late"))
        try await repo.git(["add", "tracked"])
        try repo.write("new", "new\n")
        try repo.write("leftover", "after\n")
        return try await CommitBucketPlanner.loadPlan(from: repo.service)
    }

    @Test func synthesizedDiffAndPlanValidation() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        var plan = try await dirtyPlan(repo)
        let hunks = plan.items.filter { $0.path == "tracked" }
        #expect(hunks.map(\.hunkIndex) == [0, 1])
        for item in hunks {
            let lines = UnifiedDiff.parse(item.patch).lines
            #expect(lines.count { $0.kind == "+" } == 1 && lines.count { $0.kind == "-" } == 1)
        }
        #expect(plan.buckets.count == 2 && CommitBucketPlanner.validate(plan).count == 2)
        let first = plan.buckets[0].id
        let second = plan.buckets[1].id
        plan = CommitBucketPlanner.assignFile(path: "tracked", to: first, in: plan)
        let preview = CommitBucketPlanner.synthesizedDiff(for: plan.buckets[0], in: plan)
        #expect(preview.components(separatedBy: "diff --git").count == 2)
        #expect(UnifiedDiff.parse(preview).hunks.count == 2)
        let early = try #require(hunks.first?.id)
        plan = CommitBucketPlanner.assign(itemID: early, to: second, in: plan)
        plan = CommitBucketPlanner.updateBucketMessage(second, title: " ", body: "", in: plan)
        plan.buckets[0].itemIDs.append(early)
        let issues = CommitBucketPlanner.validate(plan)
        #expect(issues.contains(.emptyTitle(bucketID: second)))
        #expect(issues.contains(.duplicateAssignment(itemID: early, bucketIDs: [first, second])))
        #expect(issues.contains { if case .hunkOrderOverlap("tracked", _) = $0 { true } else { false } })
    }

    @Test func splitCommitsPreserveUnassignedEdit() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        var plan = try await dirtyPlan(repo)
        let base = try await repo.head()
        let hunks = plan.items.filter { $0.path == "tracked" }
        let early = try #require(hunks.first)
        let late = try #require(hunks.last)
        plan = CommitBucketPlanner.assign(itemID: early.id, to: plan.buckets[0].id, in: plan)
        plan = CommitBucketPlanner.assign(itemID: late.id, to: plan.buckets[1].id, in: plan)
        plan = CommitBucketPlanner.assignFile(path: "new", to: plan.buckets[1].id, in: plan)
        plan.buckets[0].title = "Early"
        plan.buckets[1].title = "Late"
        plan.buckets[1].body = "And the new file"
        let result = try await CommitBucketExecutor(gitService: repo.service).execute(plan: plan)
        #expect(result.previousHeadID == base)
        let newHead = try await repo.head()
        #expect(result.newHeadID == newHead)
        #expect(result.branchRef == "refs/heads/main" && result.createdCommits.count == 2)
        #expect(try await repo.git(["log", "--format=%s", "-2"]).text == "Late\nEarly\n")
        #expect(try await repo.git(["show", "HEAD^:tracked"]).text == lines(early: "early"))
        #expect(try await repo.git(["show", "HEAD:tracked"]).text == lines(early: "early", late: "late"))
        #expect(try await repo.git(["show", "HEAD:new"]).text == "new\n")
        #expect(try await repo.git(["status", "--porcelain"]).text == " M leftover\n")
        #expect(try await repo.git(["diff", "--cached"]).stdout.isEmpty)
        #expect(try String(contentsOf: repo.root.appendingPathComponent("leftover"), encoding: .utf8) == "after\n")
    }

    @Test(arguments: [FailurePoint.secondCommit, .realIndex])
    func failureLeavesOriginalRefAndIndex(_ point: FailurePoint) async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        var plan = try await dirtyPlan(repo)
        plan = CommitBucketPlanner.assignFile(path: "tracked", to: plan.buckets[0].id, in: plan)
        plan = CommitBucketPlanner.assignFile(path: "new", to: plan.buckets[1].id, in: plan)
        let old = try await repo.head()
        let index = repo.root.appendingPathComponent(".git/index")
        let original = try Data(contentsOf: index)
        let runner = FailingBucketRunner(point)
        let executor = CommitBucketExecutor(gitService: .init(root: repo.root, runner: runner))
        await #expect(throws: (any Error).self) { try await executor.execute(plan: plan) }
        #expect(await runner.injected)
        #expect(try await repo.head() == old)
        #expect(try Data(contentsOf: index) == original)
    }

    @Test func unbornAndDetachedHeads() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let executor = CommitBucketExecutor(gitService: repo.service)
        try repo.write("first", "one")
        var plan = try await CommitBucketPlanner.loadPlan(from: repo.service)
        plan = CommitBucketPlanner.assignFile(path: "first", to: plan.buckets[0].id, in: plan)
        let initial = try await executor.execute(plan: plan)
        #expect(initial.previousHeadID == nil)
        try await repo.git(["checkout", "--detach", "HEAD"])
        try repo.write("first", "two")
        plan = try await CommitBucketPlanner.loadPlan(from: repo.service)
        plan = CommitBucketPlanner.assignFile(path: "first", to: plan.buckets[0].id, in: plan)
        let detached = try await executor.execute(plan: plan)
        #expect(detached.branchRef == nil && detached.previousHeadID == initial.newHeadID)
        #expect(try await repo.git(["rev-parse", "main"]).text == initial.newHeadID + "\n")
    }

    @Test func wholeFileModesBinaryAndStagedDeletion() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("removed", "remove me")
        try repo.write("script", "run this")
        try repo.write("image", data: Data([0, 2, 1]))
        try await repo.commit("Base")
        try await repo.git(["rm", "--", "removed"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.path + "/script")
        try repo.write("image", data: Data([0, 4, 3]))
        try repo.write("addition", "staged")
        try await repo.git(["add", "addition"])
        try FileManager.default.createSymbolicLink(atPath: repo.root.path + "/link", withDestinationPath: "addition")
        var plan = try await CommitBucketPlanner.loadPlan(from: repo.service)
        let kinds = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.path, $0.kind) })
        #expect(
            kinds == [
                "removed": .wholeFileDeleted, "addition": .wholeFileAdded, "link": .untrackedFile,
                "script": .wholeFileModified, "image": .wholeFileModified,
            ])
        plan.buckets[0].itemIDs = plan.items.map(\.id)
        _ = try await CommitBucketExecutor(gitService: repo.service).execute(plan: plan)
        #expect(try await repo.git(["show", "HEAD:image"]).stdout == Data([0, 4, 3]))
        #expect(try await repo.git(["show", "HEAD:link"]).text == "addition")
        #expect(try await repo.git(["ls-tree", "HEAD", "script"]).text.hasPrefix("100755 blob "))
        #expect(try await repo.git(["status", "--porcelain"]).stdout.isEmpty)
    }

    @Test func suggestionsFilterUnknownIDsAndHonorByteLimit() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("App/é.swift", "café")
        let plan = try await CommitBucketPlanner.loadPlan(from: repo.service)
        let id = try #require(plan.items.first?.id)
        let json = #"[{"title":"Title","body":"","itemIDs":["\#(id)","unknown","\#(id)"]}]"#
        let suggester = CommitBucketAgentSuggester()
        for raw in [json, "Proposed groups\n" + "```json\n" + json + "\n```"] {
            let groups = try #require(suggester.parseSuggestions(from: raw, validItemIDs: [id]))
            #expect(groups.first?.itemIDs == [id])
        }
        #expect(suggester.buildPrompt(for: plan.items, maxPromptBytes: 17).utf8.count <= 17)
        let fallback = await suggester.suggest(items: plan.items, tool: .aider, directory: repo.root)
        #expect(fallback.suggestions.first?.title == "Update App" && fallback.suggestions.first?.itemIDs == [id])
        #expect(fallback.fallbackReason != nil)
    }

    enum FailurePoint: Sendable { case secondCommit, realIndex }
}

private actor FailingBucketRunner: CommandRunning {
    let point: CommitBucketTests.FailurePoint
    var commits = 0
    private(set) var injected = false
    init(_ point: CommitBucketTests.FailurePoint) { self.point = point }

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    )
        async throws -> CommandResult
    {
        try await run(
            .init(
                executable: executable, arguments: arguments, directory: directory,
                timeout: timeout, outputLimit: outputLimit))
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.contains("commit-tree") { commits += 1 }
        let realIndex = request.arguments.contains("read-tree") && request.environment.added["GIT_INDEX_FILE"] == nil
        if (point == .secondCommit && commits == 2) || (point == .realIndex && realIndex) {
            injected = true
            throw GitError.commandFailed("Injected failure")
        }
        return try await CommandRunner().run(request)
    }
}
