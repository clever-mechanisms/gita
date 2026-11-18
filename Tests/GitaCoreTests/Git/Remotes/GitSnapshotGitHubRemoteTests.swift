import Foundation
import Testing

@testable import GitaCore

/// The snapshot's remote, read with `insteadOf` applied, and the github.com repository it reaches. Temporary fixture
/// repositories only; nothing contacts a remote.
struct GitSnapshotGitHubRemoteTests {
    private func fixture() async throws -> (root: URL, git: ([String]) async throws -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaGitHubRemote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = CommandRunner()
        let git: ([String]) async throws -> Void = { arguments in
            let result = try await runner.run(
                executable: "git", arguments: arguments, directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
        }
        try await git(["init", "--initial-branch=main", "--template="])
        let author = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"]
        try await git(author + ["commit", "--allow-empty", "-m", "one"])
        return (root, git)
    }

    @Test func insteadOfIsAppliedBeforeTheGitHubCheck() async throws {
        let (root, git) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["config", "url.git@github.com:.insteadOf", "work:"])
        try await git(["remote", "add", "origin", "work:org/repo.git"])
        let snapshot = try await GitService(root: root).snapshot()
        #expect(snapshot.remoteURL == "git@github.com:org/repo.git")
        #expect(snapshot.github?.sourceID == "github:org/repo")
    }

    @Test func theHTTPSLoginIsKeptAsAHintButNotShown() async throws {
        let (root, git) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["remote", "add", "upstream", "https://octo-cat@github.com/org/repo.git"])
        let snapshot = try await GitService(root: root).snapshot()
        #expect(snapshot.remoteURL == "https://github.com/org/repo.git", "the only remote, without its user")
        #expect(snapshot.github?.loginHint == GitHubLogin("octo-cat"))
    }

    @Test func otherRemotesHaveNoGitHubRepository() async throws {
        let (root, git) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(["remote", "add", "origin", "git@gitlab.com:org/repo.git"])
        let snapshot = try await GitService(root: root).snapshot()
        #expect(snapshot.remoteURL == "git@gitlab.com:org/repo.git")
        #expect(snapshot.github == nil)
    }
}
