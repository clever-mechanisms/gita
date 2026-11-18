import Foundation
import XCTest

@testable import GitaCore

/// cwd → checkout / repository / branch on a temporary repository with a linked worktree, plus the light workspace
/// status read. Only temporary fixtures are mutated.
final class AgentCheckoutTests: XCTestCase {
    private var container: URL!
    private var main: URL!
    private var worktree: URL!
    private let runner = CommandRunner()

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaAgentCheckout-" + UUID().uuidString, isDirectory: true
        )
        .resolvingSymlinksInPath()
        main = container.appendingPathComponent("repo", isDirectory: true)
        worktree = container.appendingPathComponent("repo-feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: main.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try await git(["init", "--initial-branch=main"])
        for setting in [
            ["user.name", "Gita Tests"], ["user.email", "tests@example.invalid"], ["commit.gpgsign", "false"],
            ["core.hooksPath", "/dev/null"],
        ] {
            try await git(["config"] + setting)
        }
        try Data("one\n".utf8).write(to: main.appendingPathComponent("Sources/App/main.txt"))
        try await git(["add", "."])
        try await git(["commit", "-m", "Initial"])
        try await git(["worktree", "add", "-b", "feature/agents", worktree.path])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: container) }

    @discardableResult private func git(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? main, timeout: 20,
            outputLimit: 1_024 * 1_024)
        guard result.exitCode == 0 else { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }

    func testFoldersMapToCheckoutRepositoryAndBranch() async throws {
        let resolver = AgentCheckoutResolver(home: container.path)
        let resolvedMain = await resolver.resolve(main.appendingPathComponent("Sources/App").path)
        let inMain = try XCTUnwrap(resolvedMain)
        XCTAssertEqual(inMain.checkoutRoot.path, main.path)
        XCTAssertEqual(inMain.repositoryRoot.path, main.path)
        XCTAssertEqual(inMain.branch, "main")

        let resolvedWorktree = await resolver.resolve(worktree.appendingPathComponent("Sources").path)
        let inWorktree = try XCTUnwrap(resolvedWorktree)
        XCTAssertEqual(inWorktree.checkoutRoot.path, worktree.path)
        XCTAssertEqual(
            inWorktree.repositoryRoot.path, main.path, "A worktree belongs to its main checkout's repository")
        XCTAssertEqual(inWorktree.branch, "feature/agents")

        let outside = container.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let missing = await resolver.resolve(outside.path)
        XCTAssertNil(missing)
        let gone = await resolver.resolve(container.appendingPathComponent("deleted").path)
        XCTAssertNil(gone)
    }

    func testCachedFolderStillSeesABranchSwitchWithoutAnotherGitCall() async throws {
        let counting = CountingRunner()
        let resolver = AgentCheckoutResolver(runner: counting, home: container.path)
        let first = await resolver.resolve(main.path)
        XCTAssertEqual(first?.branch, "main")
        try await git(["switch", "-c", "agent/fix"])
        let switched = await resolver.resolve(main.path)
        XCTAssertEqual(switched?.branch, "agent/fix")
        try await git(["switch", "--detach"])
        let detached = await resolver.resolve(main.path)
        XCTAssertNotNil(detached)
        XCTAssertNil(detached?.branch)
        let calls = await counting.calls
        XCTAssertEqual(calls, 1)
    }

    func testPrivacyProtectedFoldersAreOnlyResolvedInsideOpenedRepositories() async throws {
        // The fixture container plays HOME, so `<home>/Documents/...` is a protected location.
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let protectedRepo = documents.appendingPathComponent("notes", isDirectory: true)
        try await git(["clone", "--quiet", main.path, protectedRepo.path])
        let counting = CountingRunner()
        let resolver = AgentCheckoutResolver(runner: counting, home: container.path)
        let blocked = await resolver.resolve(protectedRepo.path)
        XCTAssertNil(blocked)
        let callsWhileBlocked = await counting.calls
        XCTAssertEqual(callsWhileBlocked, 0, "No process may touch a protected folder the user did not open")
        let allowed = await AgentCheckoutResolver(runner: counting, home: container.path).resolve(
            protectedRepo.path, allowedRoots: [protectedRepo.path])
        XCTAssertEqual(allowed?.checkoutRoot.path, protectedRepo.path)
        XCTAssertTrue(AgentCheckoutResolver.isProtected("/Volumes/USB/repo", home: "/Users/u"))
        XCTAssertFalse(AgentCheckoutResolver.isProtected("/Users/u/DocumentsArchive/repo", home: "/Users/u"))
    }

    func testWorkspaceStatusCountsChangesAheadAndLinkedWorktrees() async throws {
        let remote = container.appendingPathComponent("remote.git", isDirectory: true)
        try await git(["init", "--bare", "--quiet", remote.path], in: container)
        try await git(["remote", "add", "origin", remote.path])
        try await git(["push", "--quiet", "-u", "origin", "main"])
        try Data("two\n".utf8).write(to: main.appendingPathComponent("Sources/App/main.txt"))
        try await git(["commit", "--quiet", "-am", "Ahead"])
        try Data("three\n".utf8).write(to: main.appendingPathComponent("Sources/App/main.txt"))
        try Data("new\n".utf8).write(to: main.appendingPathComponent("untracked.txt"))
        let indexBefore =
            try FileManager.default.attributesOfItem(atPath: main.appendingPathComponent(".git/index").path)[
                .modificationDate] as? Date

        let status = try await WorkspaceStatusReader.read(root: main)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 1)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.changedFiles, 2)
        XCTAssertEqual(status.worktrees.map(\.path), [worktree.path])
        XCTAssertEqual(status.worktrees.first?.branch, "feature/agents")
        let indexAfter =
            try FileManager.default.attributesOfItem(atPath: main.appendingPathComponent(".git/index").path)[
                .modificationDate] as? Date
        XCTAssertEqual(
            indexBefore, indexAfter, "Reading status must not rewrite the index (it would retrigger the .git watcher)")

        let detached = WorkspaceStatusReader.parseStatus(
            Data("# branch.oid abc\n# branch.head (detached)\n? a\n! ignored\n".utf8))
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.changedFiles, 1)
        do {
            _ = try await WorkspaceStatusReader.read(root: container)
            XCTFail("Not a repository")
        } catch {}
    }
}

private actor CountingRunner: CommandRunning {
    private let runner = CommandRunner()
    private(set) var calls = 0
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        calls += 1
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
}
