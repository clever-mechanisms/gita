import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Web pages for remotes: a remote the snapshot resolved to github.com (an SSH alias, say) opens github.com.
@Suite("Remote page")
struct RemotePageTests {
    private func snapshot(remote: String?, github: String?) -> RepositorySnapshot {
        var snapshot = RepositorySnapshot(
            root: URL(fileURLWithPath: "/tmp/remote-page"), branch: "main", head: nil, changes: [], commits: [],
            references: [], worktrees: [], stashes: [], remoteURL: remote,
            gitDirectory: URL(fileURLWithPath: "/tmp/remote-page/.git"))
        snapshot.github = github.flatMap(RemoteAddress.init).flatMap(GitHubRemote.init(address:))
        return snapshot
    }

    @Test func anAliasTheSnapshotResolvedOpensGitHub() {
        // `work:org/repo` alone names no host a browser could open; the snapshot resolved it with `ssh -G`.
        let aliased = snapshot(remote: "work:org/repo.git", github: "git@github.com:org/repo.git")
        #expect(RemotePage.repository(aliased)?.absoluteString == "https://github.com/org/repo")
        #expect(RemoteWebPage.repository("work:org/repo.git") == nil)
    }

    @Test func otherRemotesKeepTheirHostsPage() {
        let gitlab = snapshot(remote: "git@gitlab.com:me/repo.git", github: nil)
        #expect(RemotePage.repository(gitlab)?.absoluteString == "https://gitlab.com/me/repo")
        #expect(RemotePage.repository(snapshot(remote: nil, github: nil)) == nil)
        #expect(RemotePage.repository(nil) == nil)
    }

    @Test func remotesReadOutsideASnapshotGetTheSamePages() async {
        let github = await RemotePage.branch(remote: "git@github.com:org/repo.git", branch: "feature/x")
        #expect(github?.absoluteString == "https://github.com/org/repo/tree/feature/x")
        let gitlab = await RemotePage.branch(remote: "https://gitlab.com/me/repo.git", branch: "main")
        #expect(gitlab?.absoluteString == "https://gitlab.com/me/repo/-/tree/main")
        let other = await RemotePage.branch(remote: "https://git.example.com/me/repo", branch: "main")
        #expect(other?.absoluteString == "https://git.example.com/me/repo", "no branch layout: the repository")
        #expect(await RemotePage.repository(remote: nil) == nil)
    }
}
