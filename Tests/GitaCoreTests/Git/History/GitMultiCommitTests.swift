import Foundation
import Testing

@testable import GitaCore

@Suite("Git multi-commit operations & authors")
struct GitMultiCommitTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaMulti-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func git(
        _ root: URL, author: String = "Ada", email: String = "ada@example.com", _ args: [String]
    ) async throws -> CommandResult {
        let runner = CommandRunner()
        let result = try await runner.run(
            executable: "git",
            arguments: [
                "-c", "user.name=\(author)", "-c", "user.email=\(email)", "-c", "commit.gpgsign=false",
            ] + args,
            directory: root, timeout: 20, outputLimit: 2 * 1_024 * 1_024)
        #expect(result.exitCode == 0, "git \(args) failed: \(result.text)")
        return result
    }

    @Test func topAuthorsConfiguredAuthorAndCommitDistance() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init", "--initial-branch=main", "--template="])
        _ = try await git(root, ["config", "user.name", "Local Me"])
        _ = try await git(root, ["config", "user.email", "me@example.com"])
        _ = try await git(root, author: "Ada", email: "ada@example.com", ["commit", "--allow-empty", "-m", "c1"])
        _ = try await git(root, author: "Ada", email: "ada@example.com", ["commit", "--allow-empty", "-m", "c2"])
        _ = try await git(root, author: "Bob", email: "bob@example.com", ["commit", "--allow-empty", "-m", "c3"])

        let service = GitService(root: root)
        let me = await service.configuredAuthor()
        #expect(me?.name == "Local Me")
        #expect(me?.email == "me@example.com")

        let authors = try await service.topAuthors(limit: 10)
        #expect(authors.first?.name == "Ada")
        #expect(authors.first?.commitCount == 2)
        #expect(authors.last?.name == "Bob")

        let commits = try await service.history(limit: 10, skip: 0)
        let distance = await service.commitDistance(from: commits[2].id, to: commits[0].id)
        #expect(distance == CommitDistance(behind: 0, ahead: 2))
        #expect(distance?.isLinear == true)
        #expect(distance?.total == 2)
    }

    @Test func multiCommitCherryPickAndRevertOnFixtureRepo() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init", "--initial-branch=main", "--template="])
        try "base\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "base.txt"])
        _ = try await git(root, ["commit", "-m", "Base"])

        _ = try await git(root, ["checkout", "-q", "-b", "topic"])
        try "one\n".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "one.txt"])
        _ = try await git(root, ["commit", "-m", "Add one"])
        let oneSHA = GitOutput.withoutTerminalLF(try await git(root, ["rev-parse", "HEAD"]).text)

        try "two\n".write(to: root.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "two.txt"])
        _ = try await git(root, ["commit", "-m", "Add two"])
        let twoSHA = GitOutput.withoutTerminalLF(try await git(root, ["rev-parse", "HEAD"]).text)

        _ = try await git(root, ["checkout", "-q", "main"])
        let service = GitService(root: root)
        let pickOutcome = try await service.cherryPick(commits: [oneSHA, twoSHA])
        guard case .completed = pickOutcome else {
            Issue.record("Expected cherry-pick to complete")
            return
        }

        let mainCommits = try await service.history(limit: 10, skip: 0)
        #expect(mainCommits.prefix(2).map(\.subject) == ["Add two", "Add one"])

        let revertOutcome = try await service.revert(commits: [mainCommits[0].id, mainCommits[1].id])
        guard case .completed = revertOutcome else {
            Issue.record("Expected revert to complete")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("two.txt").path))
    }
}
