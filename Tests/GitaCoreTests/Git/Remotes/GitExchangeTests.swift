import Foundation
import Testing

@testable import GitaCore

/// A working copy with two bare remotes (`origin` and `backup`) and a peer clone of `origin` that pushes to them.
private struct ExchangeFixture {
    let container: URL, root: URL, origin: URL, backup: URL, peer: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("GitaExchange-" + UUID().uuidString)
        root = container.appendingPathComponent("work tree")
        origin = container.appendingPathComponent("origin.git")
        backup = container.appendingPathComponent("backup.git")
        peer = container.appendingPathComponent("peer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        for bare in [origin, backup] {
            try await git(["init", "--bare", "--initial-branch=main", bare.path], at: container)
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try await configure(root)
        try await git(["remote", "add", "origin", origin.path])
        try await git(["remote", "add", "backup", backup.path])
        try write("a.txt", "one\n")
        try await commit("Base")
        try await git(["push", "-u", "origin", "main"])
        try await git(["clone", "--quiet", origin.path, peer.path], at: container)
        try await configure(peer)
    }

    private func configure(_ directory: URL) async throws {
        for (key, value) in [
            ("user.name", "Exchange Tests"), ("user.email", "exchange@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
        ] { try await git(["config", key, value], at: directory) }
    }

    func remove() { try? FileManager.default.removeItem(at: container) }

    func write(_ path: String, _ value: String, at directory: URL? = nil) throws {
        try Data(value.utf8).write(to: (directory ?? root).appendingPathComponent(path))
    }

    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? root, timeout: 20, outputLimit: 1 << 20)
        if result.exitCode != 0 { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }

    func revision(_ ref: String, at directory: URL? = nil) async throws -> String {
        try await git(["rev-parse", ref], at: directory).text.trimmingCharacters(in: .newlines)
    }

    @discardableResult func commit(_ message: String, at directory: URL? = nil) async throws -> String {
        try await git(["add", "--all"], at: directory)
        try await git(["commit", "--quiet", "-m", message], at: directory)
        return try await revision("HEAD", at: directory)
    }

    /// A commit the peer pushes to `origin`'s main (and, as `extra`, to `backup`).
    func peerCommit(_ path: String) async throws -> String {
        try write(path, path + "\n", at: peer)
        let tip = try await commit("Peer " + path, at: peer)
        try await git(["push", "--quiet", "origin", "main"], at: peer)
        try await git(["push", "--quiet", backup.path, "main:refs/heads/extra"], at: peer)
        return tip
    }
}

@Suite("Fetch, pull and push from the sheets")
struct GitExchangeTests {
    @Test func fetchTakesOneRemoteOrAll() async throws {
        let fixture = try await ExchangeFixture()
        defer { fixture.remove() }
        let tip = try await fixture.peerCommit("b.txt")
        try await fixture.service.fetch(remote: "origin")
        #expect(try await fixture.revision("refs/remotes/origin/main") == tip)
        await #expect(throws: GitError.self) { _ = try await fixture.revision("refs/remotes/backup/extra") }
        try await fixture.service.fetch(remote: nil)
        #expect(try await fixture.revision("refs/remotes/backup/extra") == tip)
        await expectGitError(.invalidRemote) { try await fixture.service.fetch(remote: "--all") }
        await expectGitError(.invalidRemote) { try await fixture.service.fetch(remote: "missing") }
    }

    @Test func pullMergesOrRebasesAndCanKeepLocalChangesAside() async throws {
        let fixture = try await ExchangeFixture()
        defer { fixture.remove() }
        let first = try await fixture.peerCommit("b.txt")
        try fixture.write("local.txt", "local\n")
        let local = try await fixture.commit("Local")
        let merged = try await fixture.service.pull(GitPullRequest(remote: "origin", branch: "main"))
        guard case .completed = merged else {
            Issue.record("The merge stopped")
            return
        }
        #expect(try await fixture.revision("HEAD^1") == local)
        #expect(try await fixture.revision("HEAD^2") == first)

        let second = try await fixture.peerCommit("c.txt")
        try fixture.write("a.txt", "edited\n")
        let rebase = GitPullRequest(remote: "origin", branch: "main", mode: .rebase)
        await expectGitError(.dirtyTrackedFiles) { _ = try await fixture.service.pull(rebase) }
        var stashing = rebase
        stashing.autostash = true
        guard case .completed = try await fixture.service.pull(stashing) else {
            Issue.record("The rebase stopped")
            return
        }
        #expect(try await fixture.git(["merge-base", "--is-ancestor", second, "HEAD"]).exitCode == 0)
        #expect(try await fixture.git(["rev-list", "--merges", second + "..HEAD"]).text.isEmpty)
        let edited = try String(contentsOf: fixture.root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(edited == "edited\n")
        await expectGitError(.invalidRemote) {
            _ = try await fixture.service.pull(GitPullRequest(remote: "missing", branch: "main", autostash: true))
        }
    }

    @Test func pushSendsABranchWhereChosenWithTagsOrForced() async throws {
        let fixture = try await ExchangeFixture()
        defer { fixture.remove() }
        try await fixture.git(["switch", "--quiet", "-c", "topic"])
        try fixture.write("t.txt", "t\n")
        let tip = try await fixture.commit("Topic")
        try await fixture.git(["tag", "v1"])
        try await fixture.service.push(
            GitPushRequest(branch: "topic", remote: "backup", remoteBranch: "topic", tags: true))
        #expect(try await fixture.revision("refs/heads/topic", at: fixture.backup) == tip)
        #expect(try await fixture.revision("refs/tags/v1", at: fixture.backup) == tip)
        // Untracked until now: it tracks where it went; a tracking branch keeps its upstream.
        try await fixture.service.push(GitPushRequest(branch: "main", remote: "backup", remoteBranch: "release"))
        #expect(try await fixture.revision("refs/heads/release", at: fixture.backup) == fixture.revision("main"))
        let upstreams = try await fixture.service.branchUpstreams()
        #expect(upstreams["topic"] == GitBranchUpstream(remote: "backup", branch: "topic"))
        #expect(upstreams["main"] == GitBranchUpstream(remote: "origin", branch: "main"))

        try await fixture.git(["commit", "--quiet", "--amend", "-m", "Topic again"])
        let amended = try await fixture.revision("HEAD")
        let plain = GitPushRequest(branch: "topic", remote: "backup", remoteBranch: "topic")
        await #expect(throws: GitError.self) { try await fixture.service.push(plain) }
        var forced = plain
        forced.force = true
        try await fixture.service.push(forced)
        #expect(try await fixture.revision("refs/heads/topic", at: fixture.backup) == amended)
        await #expect(throws: GitError.self) {
            try await fixture.service.push(GitPushRequest(branch: "missing", remote: "origin", remoteBranch: "x"))
        }
        await expectGitError(.invalidRemote) {
            try await fixture.service.push(GitPushRequest(branch: "topic", remote: "-x", remoteBranch: "x"))
        }
    }

    @Test func upstreamsOnlyNameConfiguredRemotes() {
        let text = "main\0origin\0refs/heads/main\nlocal\0.\0refs/heads/main\nloose\0\0\nodd\0origin\0refs/tags/x\n"
        let upstreams = GitService.branchUpstreams(text, remotes: ["origin"])
        #expect(upstreams == ["main": GitBranchUpstream(remote: "origin", branch: "main")])
    }
}
