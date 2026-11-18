import Foundation
import Testing

@testable import GitaCore

struct HistoryScopeTests {
    @Test func revisionsAndRestriction() {
        #expect(HistoryScope.all.revisions == ["--all"])
        #expect(HistoryScope(hidden: ["refs/heads/a*b"]).revisions == ["--exclude=refs/heads/a\\*b", "--all"])
        #expect(
            HistoryScope(only: ["refs/heads/b", "refs/heads/a", "refs/heads/a"]).revisions == [
                "--end-of-options", "refs/heads/a", "refs/heads/b",
            ])
        // Not a reference name: dropped.
        #expect(HistoryScope(only: ["--output=x", "HEAD"], hidden: ["-x"]).isAll)
        let scope = HistoryScope(
            only: ["refs/heads/gone", "refs/heads/a"], hidden: ["refs/heads/a", "refs/heads/old"])
        #expect(scope.restricted(to: ["refs/heads/a"]) == HistoryScope(hidden: ["refs/heads/a"]))
        #expect(HistoryScope(only: ["refs/heads/gone"]).restricted(to: ["refs/heads/a"]).isAll)
    }

    @Test func historyWalksOnlyTheScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaHistoryScope-" + UUID().uuidString)
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
        try await git(["commit", "--allow-empty", "-m", "base"])
        try await git(["switch", "-c", "a"])
        try await git(["commit", "--allow-empty", "-m", "on a"])
        try await git(["switch", "-c", "b", "main"])
        try await git(["commit", "--allow-empty", "-m", "on b"])
        try await git(["switch", "main"])
        try await git(["commit", "--allow-empty", "-m", "on main"])
        let service = GitService(root: root)
        func subjects(_ scope: HistoryScope) async throws -> Set<String> {
            Set(try await service.history(limit: 50, skip: 0, scope: scope).map(\.subject))
        }

        #expect(try await subjects(.all) == ["base", "on a", "on b", "on main"])
        #expect(try await subjects(HistoryScope(only: ["refs/heads/a"])) == ["base", "on a"])
        #expect(try await subjects(HistoryScope(only: ["refs/heads/a", "refs/heads/b"])) == ["base", "on a", "on b"])
        // Hidden: left out of --all.
        #expect(try await subjects(HistoryScope(hidden: ["refs/heads/b"])) == ["base", "on a", "on main"])
        // HEAD is still walked: hiding the current branch keeps its commits.
        #expect(
            try await subjects(HistoryScope(hidden: ["refs/heads/main", "refs/heads/a"])) == [
                "base", "on b", "on main",
            ])

        // The snapshot drops references that no longer exist and reports what it walked.
        let snapshot = try await service.snapshot(
            limit: 50, scope: HistoryScope(only: ["refs/heads/a", "refs/heads/gone"]))
        #expect(snapshot.historyScope == HistoryScope(only: ["refs/heads/a"]))
        #expect(Set(snapshot.commits.map(\.subject)) == ["base", "on a"])
        #expect(snapshot.references.count == 3)
        let everything = try await service.snapshot(limit: 50)
        #expect(everything.commits.count == 4)
    }
}
