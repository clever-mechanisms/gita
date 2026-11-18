import Foundation
import Testing

@testable import GitaCore

struct WalkTipsTests {
    private static let a = String(repeating: "a", count: 40)
    private static let b = String(repeating: "b", count: 40)
    private static let c = String(repeating: "c", count: 40)
    private static let t = String(repeating: "f", count: 40)

    /// `GitArguments.referenceList` records from (name, type, object, peeled type, peeled object).
    private static func listing(_ records: [[String]]) -> Data {
        let lines = records.map { record in
            [record[0], record[2], "", record[4], record[1], record[3]].joined(separator: "\0") + "\0\n"
        }
        return Data(lines.joined().utf8)
    }

    @Test func tipsFollowTheScope() throws {
        let data = Self.listing([
            ["refs/heads/main", "commit", Self.a, "", ""],
            ["refs/heads/topic", "commit", Self.b, "", ""],
            ["refs/tags/v1", "tag", Self.t, "commit", Self.c],
            ["refs/tags/tree", "tag", Self.t, "tree", Self.t],
            ["refs/tags/light", "commit", Self.a, "", ""],
        ])
        // Everything in `--all`'s order (the references, HEAD, the other worktrees' HEADs), without repeats; a tag of
        // a tree walks nothing.
        #expect(WalkTips.commits(data, scope: .all, head: Self.c) == [Self.a, Self.b, Self.c])
        #expect(WalkTips.commits(data, scope: .all, head: nil) == [Self.a, Self.b, Self.c])
        #expect(
            WalkTips.commits(data, scope: .all, head: Self.b, worktreeHeads: [Self.t, Self.a]) == [
                Self.a, Self.b, Self.c, Self.t,
            ])
        // Hidden references are left out, HEAD stays.
        #expect(
            WalkTips.commits(data, scope: HistoryScope(hidden: ["refs/heads/topic"]), head: Self.b) == [
                Self.a, Self.c, Self.b,
            ])
        #expect(
            WalkTips.commits(data, scope: HistoryScope(only: ["refs/heads/main"]), head: nil, worktreeHeads: [Self.t])
                == [Self.a])
        // Only the chosen ones, without HEAD.
        #expect(WalkTips.commits(data, scope: HistoryScope(only: ["refs/tags/v1"]), head: Self.a) == [Self.c])
        // A chosen reference that is gone, a tag of a tag or a malformed object: Git's own arguments decide.
        #expect(WalkTips.commits(data, scope: HistoryScope(only: ["refs/heads/gone"]), head: nil).isEmpty)
        let nested = Self.listing([["refs/tags/v2", "tag", Self.t, "tag", Self.t]])
        #expect(WalkTips.commits(nested, scope: .all, head: nil).isEmpty)
        let malformed = Self.listing([["refs/heads/x", "commit", "--all", "", ""]])
        #expect(WalkTips.commits(malformed, scope: .all, head: nil).isEmpty)
        #expect(WalkTips.commits(Data(), scope: .all, head: "HEAD").isEmpty)
        // An unborn repository: nothing to walk, so Git's own arguments (an empty list would mean HEAD).
        #expect(WalkTips.commits(Data(), scope: .all, head: nil).isEmpty)
    }

    @Test func reductionPaysWhenItLeavesFewOrRemovesMost() {
        let tips = (0..<1_000).map { String(format: "%040x", $0) }
        #expect(WalkTips.worthWalking(Array(tips.prefix(1)), of: tips))
        #expect(WalkTips.worthWalking(Array(tips.prefix(256)), of: tips))
        #expect(WalkTips.worthWalking(Array(tips.prefix(500)), of: tips))
        #expect(!WalkTips.worthWalking(Array(tips.prefix(501)), of: tips))
    }

    @Test func independentKeepsTipOrder() {
        let tips = [Self.a, Self.b, Self.c]
        #expect(WalkTips.independent(Data((Self.c + "\n" + Self.a + "\n").utf8), of: tips) == [Self.a, Self.c])
        // Anything Git was not asked about, or nothing at all: not trusted.
        #expect(WalkTips.independent(Data((Self.t + "\n").utf8), of: tips).isEmpty)
        #expect(WalkTips.independent(Data(), of: tips).isEmpty)
    }

    /// With a commit-graph the walk starts from the independent tips only and prints exactly what `--all` prints;
    /// without one it keeps `--all`.
    @Test func prunedWalkMatchesTheFullWalk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaWalkTips-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: [
                    "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", "-c",
                    "tag.gpgsign=false",
                ] + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text
        }
        try await git(["init", "--initial-branch=main", "--template="])
        for index in 0..<6 {
            try await git(["commit", "--allow-empty", "-m", "main \(index)"])
            try await git(["tag", "-a", "-m", "release", "v\(index)"])
        }
        try await git(["switch", "-c", "topic", "v2"])
        try await git(["commit", "--allow-empty", "-m", "on topic"])
        try await git(["switch", "--orphan", "pages"])
        try await git(["commit", "--allow-empty", "-m", "unrelated"])
        try await git(["switch", "main"])
        try await git(["merge", "--no-ff", "-m", "merge topic", "topic"])
        try await git(["tag", "light", "v1^{commit}"])
        let service = GitService(root: root)
        let format = ["log", "--topo-order", "--format=%H %s", "--max-count=50"]

        // No commit-graph: Git's own arguments.
        #expect(try await service.walkRevisions(.all) == ["--all"])

        try await git(["commit-graph", "write", "--reachable"])
        let pruned = try await service.walkRevisions(.all)
        // HEAD (main) reaches every tag and topic; the orphan branch is the only other independent tip.
        #expect(pruned.count == 2)
        #expect(try await git(format + pruned + ["--"]) == git(format + ["--all", "--"]))
        // A first read races Git's own revisions against the reduced tips: either way, the same page.
        let raced = try await GitService(root: root).snapshot(limit: 50)
        let everything = try await git(format + ["--all", "--"])
        #expect(raced.commits.map { $0.id + " " + $0.subject }.joined(separator: "\n") + "\n" == everything)
        let page = try await service.history(limit: 3, skip: 2)
        let expected = try await git(format + ["--all", "--skip=2", "--max-count=3", "--"])
        #expect(page.map { $0.id + " " + $0.subject }.joined(separator: "\n") + "\n" == expected)

        // Scopes: hidden references and chosen ones walk what Git's own arguments walk.
        let hidden = HistoryScope(hidden: ["refs/heads/pages"])
        let hiddenWalk = try await git(format + service.walkRevisions(hidden) + ["--"])
        #expect(try await hiddenWalk == git(format + hidden.revisions + ["--"]))
        let only = HistoryScope(only: ["refs/heads/topic", "refs/tags/v4"])
        #expect(try await service.walkRevisions(only).count == 2)
        let onlyWalk = try await git(format + service.walkRevisions(only) + ["--"])
        #expect(try await onlyWalk == git(format + only.revisions + ["--"]))

        // core.commitGraph=false: Git reads no graph, so neither does the reduction.
        try await git(["config", "core.commitGraph", "false"])
        let other = GitService(root: root)
        #expect(try await other.walkRevisions(.all) == ["--all"])
    }

    /// Branch tips with the same commit date, and a commit only another worktree's detached HEAD reaches: the reduced
    /// walk prints what `--all` prints, page by page.
    @Test func tiedTipsAndOtherWorktreesWalkLikeAll() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GitaTies-" + UUID().uuidString)
        let root = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = CommandRunner()
        @discardableResult
        func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
            // Every commit at the same second: Git then keeps the order its tips were given in.
            let result = try await runner.run(
                executable: "/usr/bin/env",
                arguments: [
                    "GIT_AUTHOR_DATE=@1577836800 +0000", "GIT_COMMITTER_DATE=@1577836800 +0000", "git", "-c",
                    "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                ] + arguments,
                directory: directory ?? root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["commit", "--allow-empty", "-m", "base"])
        try await git(["branch", "a"])
        try await git(["branch", "z"])
        try await git(["commit", "--allow-empty", "-m", "on main"])
        for branch in ["a", "z"] {
            try await git(["switch", branch])
            try await git(["commit", "--allow-empty", "-m", "on \(branch)"])
        }
        try await git(["switch", "main"])
        let other = base.appendingPathComponent("other")
        try await git(["worktree", "add", "--detach", other.path])
        try await git(["commit", "--allow-empty", "-m", "only in the other worktree"], in: other)
        try await git(["commit-graph", "write", "--reachable"])

        let service = GitService(root: root)
        let format = ["log", "--topo-order", "--format=%s"]
        let everything = try await git(format + ["--all", "--"])
        #expect(everything.contains("only in the other worktree"))
        let reduced = try await service.walkRevisions(.all)
        #expect(reduced != ["--all"])
        #expect(try await git(format + reduced + ["--"]) == everything)
        let first = try await service.history(limit: 2, skip: 0)
        let rest = try await service.history(limit: 10, skip: 2)
        #expect((first + rest).map(\.subject).joined(separator: "\n") + "\n" == everything)
    }

    /// A slow walk without a commit-graph asks for one; once built (or with `core.commitGraph` off) it does not.
    @Test func slowWalkBuildsACommitGraphOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaGraph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        func git(_ arguments: [String]) async throws {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["commit", "--allow-empty", "-m", "one"])
        try await git(["commit", "--allow-empty", "-m", "two"])
        let service = GitService(root: root)
        _ = try await service.history(limit: 10, skip: 0)
        // A fast walk: nothing to build.
        #expect(await !service.commitGraphWouldHelp())
        await service.noteWalk(.seconds(2))
        #expect(await service.commitGraphWouldHelp())
        try await service.buildCommitGraph()
        let graph = root.appendingPathComponent(".git/objects/info/commit-graph")
        #expect(FileManager.default.fileExists(atPath: graph.path))
        await service.noteWalk(.seconds(2))
        #expect(await !service.commitGraphWouldHelp())
        #expect(try await service.history(limit: 10, skip: 0).map(\.subject) == ["two", "one"])

        try FileManager.default.removeItem(at: graph)
        try await git(["config", "core.commitGraph", "false"])
        await service.noteWalk(.seconds(2))
        #expect(await !service.commitGraphWouldHelp())
    }

    /// A history walk counts once it has run for `slowWalk` and no status read runs beside it; a walk that ends
    /// does not end a newer one.
    @Test func slowWalkAloneOnlyWhileAWalkOutlastsStatus() async {
        let service = GitService(root: FileManager.default.temporaryDirectory)
        let start = ContinuousClock.now
        #expect(await !service.slowWalkAlone(now: start + .seconds(5)))
        await service.startWalk(start)
        #expect(await !service.slowWalkAlone(now: start + .milliseconds(100)))
        #expect(await service.slowWalkAlone(now: start + GitService.slowWalk))
        await service.setStatusReads(1)
        #expect(await !service.slowWalkAlone(now: start + .seconds(1)))
        await service.setStatusReads(0)
        await service.noteWalk(.milliseconds(10), start: start - .seconds(1))
        #expect(await service.slowWalkAlone(now: start + .seconds(1)))
        await service.noteWalk(.seconds(1), start: start)
        #expect(await !service.slowWalkAlone(now: start + .seconds(2)))
    }

    /// Hundreds of unrelated branches do not reduce: their own arguments are walked, and the next pages skip the
    /// reduction for a while.
    @Test func branchesThatDoNotReduceKeepGitsArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaTips-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return GitOutput.withoutTerminalLF(result.text)
        }
        _ = try await git(["init", "--initial-branch=main", "--template="])
        _ = try await git(["commit", "--allow-empty", "-m", "main"])
        let tree = try await git(["write-tree"])
        // Root commits written as loose references: no commit reaches another.
        let heads = root.appendingPathComponent(".git/refs/heads")
        for index in 0..<300 {
            let commit = try await git(["commit-tree", tree, "-m", "orphan \(index)"])
            try Data((commit + "\n").utf8).write(to: heads.appendingPathComponent("orphan-\(index)"))
        }
        _ = try await git(["commit-graph", "write", "--reachable"])
        let service = GitService(root: root)
        #expect(try await service.walkRevisions(.all) == ["--all"])
        #expect(await service.walkTipsUnhelpful?.scope == .all)
        // Another scope is reduced on its own merits.
        let one = HistoryScope(only: ["refs/heads/orphan-1"])
        #expect(try await service.walkRevisions(one).count == 1)
        #expect(try await service.history(limit: 400, skip: 0).count == 301)
    }
}

extension GitService {
    func setStatusReads(_ count: Int) { statusReads = count }
}
