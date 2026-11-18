import Foundation
import Testing

@testable import GitaCore

/// A working copy and a second clone (“elsewhere”) sharing a bare origin, so the remote can move on without us.
struct SyncFixture {
    let container: URL, root: URL, origin: URL, elsewhere: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("GitaSync-" + UUID().uuidString)
        root = container.appendingPathComponent("work tree")
        origin = container.appendingPathComponent("origin.git")
        elsewhere = container.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--bare", "--initial-branch=main", origin.path], at: container)
        try await git(["init", "--initial-branch=main", "--template="])
        try await configure(root)
        try await git(["remote", "add", "origin", origin.path])
        try write("a.txt", "one\n")
        try await commit("Base")
        try await git(["push", "-u", "origin", "main"])
        try await git(["clone", "--template=", origin.path, elsewhere.path], at: container)
        try await configure(elsewhere)
    }
    private func configure(_ directory: URL) async throws {
        for (key, value) in [
            ("user.name", "Sync Tests"), ("user.email", "sync@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
        ] { try await git(["config", key, value], at: directory) }
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func write(_ path: String, _ value: String, in directory: URL? = nil) throws {
        try Data(value.utf8).write(to: (directory ?? root).appendingPathComponent(path))
    }
    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? root, timeout: 20, outputLimit: 1 << 20)
        if result.exitCode != 0 { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }
    func value(_ arguments: [String], at directory: URL? = nil) async throws -> String {
        try await git(arguments, at: directory).text.trimmingCharacters(in: .newlines)
    }
    @discardableResult func commit(_ message: String, in directory: URL? = nil) async throws -> String {
        try await git(["add", "--all"], at: directory)
        try await git(["commit", "-m", message], at: directory)
        return try await value(["rev-parse", "HEAD"], at: directory)
    }
    /// Keeps the newest branch-reflog line, so the rewritten commit survives only as that line's old oid.
    func keepOnlyLatestReflogEntry(_ branch: String = "main") throws {
        let log = root.appendingPathComponent(".git/logs/refs/heads/" + branch)
        let text = try String(contentsOf: log, encoding: .utf8)
        guard let last = text.split(separator: "\n", omittingEmptySubsequences: true).last else { return }
        try Data((last + "\n").utf8).write(to: log)
    }
    /// A commit pushed to origin from the other clone.
    @discardableResult func remoteCommit(_ path: String, _ contents: String, _ message: String) async throws -> String {
        try write(path, contents, in: elsewhere)
        let id = try await commit(message, in: elsewhere)
        try await git(["push", "origin", "main"], at: elsewhere)
        return id
    }
    /// Pulls origin's main into the checked-out branch.
    @discardableResult func pull(_ mode: GitPullMode) async throws -> GitOperationOutcome {
        try await service.pull(GitPullRequest(remote: "origin", branch: "main", mode: mode))
    }
    func parents(_ ref: String = "HEAD") async throws -> Int {
        try await value(["rev-list", "--parents", "-n", "1", ref]).split(separator: " ").count - 1
    }
}

@Suite(.serialized)
struct GitSyncTests {
    @Test func pullIntoABranchWithoutAnUpstreamTakesTheChosenRemoteBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let tip = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try await fixture.git(["branch", "--unset-upstream"])
        try await fixture.pull(.fastForwardOnly)
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == tip)
    }

    @Test func fastForwardOnlyPullRefusesDivergedHistoryAndChangesNothing() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("c.txt", "c\n")
        let local = try await fixture.commit("Local")
        await #expect(throws: GitError.self) { try await fixture.pull(.fastForwardOnly) }
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == local)
        #expect(try await fixture.service.operationState() == nil)
    }

    @Test func mergePullJoinsDivergedHistoryWithAMergeCommit() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("c.txt", "c\n")
        let local = try await fixture.commit("Local")
        // The user's own pull.rebase / pull.ff do not override the chosen mode.
        try await fixture.git(["config", "pull.rebase", "true"])
        try await fixture.git(["config", "pull.ff", "only"])
        guard case .completed = try await fixture.pull(.merge) else {
            Issue.record("merge pull stopped")
            return
        }
        #expect(try await fixture.parents() == 2)
        #expect(try await fixture.value(["rev-parse", "HEAD^1"]) == local)
        #expect(try await fixture.value(["rev-parse", "HEAD^2"]) == remote)
    }

    @Test func mergePullFastForwardsWhenItCan() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try await fixture.pull(.merge)
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == remote)
    }

    @Test func rebasePullReplaysLocalCommitsOnTopOfTheRemote() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("c.txt", "c\n")
        try await fixture.commit("Local")
        try await fixture.git(["config", "pull.rebase", "false"])
        guard case .completed = try await fixture.pull(.rebase) else {
            Issue.record("rebase pull stopped")
            return
        }
        #expect(try await fixture.parents() == 1)
        #expect(try await fixture.value(["rev-parse", "HEAD^"]) == remote)
        #expect(try await fixture.value(["log", "-1", "--format=%s"]) == "Local")
    }

    @Test func conflictingPullsStopAsAnOperationToResolve() async throws {
        for mode in [GitPullMode.merge, .rebase] {
            let fixture = try await SyncFixture()
            defer { fixture.remove() }
            try await fixture.remoteCommit("a.txt", "remote\n", "Remote")
            try fixture.write("a.txt", "local\n")
            try await fixture.commit("Local")
            guard case .stopped(let state, _) = try await fixture.pull(mode) else {
                Issue.record("\(mode) pull did not stop on the conflict")
                continue
            }
            #expect(state.kind == (mode == .merge ? .merge : .rebase))
        }
    }

    @Test func mergeAndRebasePullsRefuseUncommittedTrackedChanges() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("a.txt", "dirty\n")
        for mode in [GitPullMode.merge, .rebase] {
            await expectGitError(.dirtyTrackedFiles) { try await fixture.pull(mode) }
        }
    }

    @Test func pushWithoutAnUpstreamPublishesTheCurrentBranchAndTracksIt() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.git(["switch", "-c", "feature"])
        try fixture.write("f.txt", "f\n")
        let tip = try await fixture.commit("Feature")
        try await fixture.service.push()
        #expect(try await fixture.value(["rev-parse", "refs/heads/feature"], at: fixture.origin) == tip)
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == "origin/feature")
    }

    @Test func forceFlagsKeepTheIncludesCheckUnlessTheRemoteTipIsOnlyTheReflogPrior() {
        #expect(ForcePushFlags.arguments(force: false).isEmpty)
        #expect(ForcePushFlags.arguments(force: true) == ["--force-with-lease", "--force-if-includes"])
        #expect(
            ForcePushFlags.arguments(force: true, rewroteUnrecordedTip: true)
                == ["--force-with-lease", "--no-force-if-includes"])
    }

    @Test func plainPushIsRejectedAfterARewriteAndForcePushReplacesTheRemoteBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try fixture.write("b.txt", "b\n")
        try await fixture.commit("Pushed")
        try await fixture.service.push()
        try fixture.write("b.txt", "amended\n")
        try await fixture.git(["add", "--all"])
        try await fixture.git(["commit", "--amend", "-m", "Amended"])
        let amended = try await fixture.value(["rev-parse", "HEAD"])
        await #expect(throws: GitError.self) { try await fixture.service.push() }
        try await fixture.service.push(force: true)
        #expect(try await fixture.value(["rev-parse", "refs/heads/main"], at: fixture.origin) == amended)
    }

    @Test func forcePushReplacesTheRemoteWhenTheReflogOnlyRecordsTheAmend() async throws {
        for useSheet in [false, true] {
            let fixture = try await SyncFixture()
            defer { fixture.remove() }
            try await fixture.git(["config", "push.useForceIfIncludes", "true"])
            try fixture.write("b.txt", "b\n")
            try await fixture.commit("Pushed")
            try await fixture.service.push()
            try fixture.write("b.txt", "amended\n")
            try await fixture.git(["add", "--all"])
            try await fixture.git(["commit", "--amend", "-m", "Amended"])
            let amended = try await fixture.value(["rev-parse", "HEAD"])
            try fixture.keepOnlyLatestReflogEntry()
            await #expect(throws: GitError.self) { try await fixture.service.push() }
            if useSheet {
                try await fixture.service.push(
                    GitPushRequest(branch: "main", remote: "origin", remoteBranch: "main", force: true))
            } else {
                try await fixture.service.push(force: true)
            }
            #expect(try await fixture.value(["rev-parse", "refs/heads/main"], at: fixture.origin) == amended)
        }
    }

    @Test func forcePushRefusesToDropRemoteCommitsNotSeenHere() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Someone else's")
        try fixture.write("c.txt", "c\n")
        try await fixture.commit("Mine")
        // Not fetched: the lease does not match.
        await #expect(throws: GitError.self) { try await fixture.service.push(force: true) }
        // Fetched (as a background fetch would) but never integrated: --force-if-includes still refuses.
        try await fixture.service.fetch(remote: nil)
        await #expect(throws: GitError.self) { try await fixture.service.push(force: true) }
        #expect(try await fixture.value(["rev-parse", "refs/heads/main"], at: fixture.origin) == remote)
    }

    @Test func forcePushPublishesABranchWithoutAnUpstream() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.git(["switch", "-c", "feature"])
        try fixture.write("f.txt", "f\n")
        let tip = try await fixture.commit("Feature")
        try await fixture.service.push(force: true)
        #expect(try await fixture.value(["rev-parse", "refs/heads/feature"], at: fixture.origin) == tip)
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == "origin/feature")
    }
}
