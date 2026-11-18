import Foundation
import Testing

@testable import GitaCore

struct RemoteWebPageTests {
    private func page(_ remote: String) -> String? { RemoteWebPage.repository(remote)?.absoluteString }

    @Test func commonRemoteFormsMapToTheRepositoryPage() {
        #expect(page("git@github.com:owner/repo.git") == "https://github.com/owner/repo")
        #expect(page("https://github.com/owner/repo.git") == "https://github.com/owner/repo")
        #expect(page("https://github.com/owner/repo/") == "https://github.com/owner/repo")
        #expect(page("ssh://git@github.com/owner/repo.git") == "https://github.com/owner/repo")
        #expect(page("ssh://git@github.com:22/owner/repo") == "https://github.com/owner/repo")
        #expect(page("git@gitlab.com:group/sub/repo.git") == "https://gitlab.com/group/sub/repo")
        #expect(page("git@bitbucket.org:team/repo.git") == "https://bitbucket.org/team/repo")
        #expect(page("https://codeberg.org/owner/repo") == "https://codeberg.org/owner/repo")
        #expect(page("git@ssh.dev.azure.com:v3/org/project/repo") == "https://dev.azure.com/org/project/_git/repo")
        #expect(page("https://git.example.com:8443/team/repo.git") == "https://git.example.com:8443/team/repo")
        #expect(page("git@github.com-work:owner/repo.git") == "https://github.com/owner/repo")
    }

    @Test func credentialsAndQueriesNeverReachThePage() {
        #expect(page("https://user:token@github.com/owner/repo.git?x=1#y") == "https://github.com/owner/repo")
        #expect(page("http://github.com/owner/repo") == "https://github.com/owner/repo")
    }

    @Test func localAndUnusableRemotesHaveNoPage() {
        for remote in [
            "", "/tmp/repo.git", "../repo", "~/repo", "file:///tmp/repo", "ext::ssh -i key host", "alias:owner/repo",
            "git@github.com:repo.git", "https://github.com/", "git@host.example:~user/repo",
            "Unsupported repository URL",
        ] {
            #expect(RemoteWebPage.repository(remote) == nil, "\(remote)")
        }
    }

    @Test func branchPagesFollowEachHostsLayout() {
        #expect(
            RemoteWebPage.branch("git@github.com:o/r.git", branch: "feature/x")?.absoluteString
                == "https://github.com/o/r/tree/feature/x")
        #expect(
            RemoteWebPage.branch("git@gitlab.com:g/r.git", branch: "main")?.absoluteString
                == "https://gitlab.com/g/r/-/tree/main")
        #expect(
            RemoteWebPage.branch("git@bitbucket.org:t/r.git", branch: "dev")?.absoluteString
                == "https://bitbucket.org/t/r/src/dev")
        #expect(
            RemoteWebPage.branch("https://codeberg.org/o/r", branch: "dev")?.absoluteString
                == "https://codeberg.org/o/r/src/branch/dev")
        #expect(
            RemoteWebPage.branch("git@github.com:o/r.git", branch: "a#b?c")?.absoluteString
                == "https://github.com/o/r/tree/a%23b%3Fc")
        #expect(RemoteWebPage.branch("git@git.example.com:o/r.git", branch: "main") == nil)
    }

    @Test func hostNames() {
        #expect(RemoteWebPage.repository("git@github.com:o/r").map(RemoteWebPage.hostName) == "GitHub")
        #expect(RemoteWebPage.repository("git@gitlab.example.com:o/r").map(RemoteWebPage.hostName) == "GitLab")
        #expect(RemoteWebPage.repository("git@git.example.com:o/r").map(RemoteWebPage.hostName) == "git.example.com")
    }
}

struct RemoteLookupTests {
    @Test func remoteURLsAreReadFromConfigurationOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaRemotePage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        func git(_ arguments: [String]) async throws {
            let result = try await runner.run(
                executable: "git", arguments: arguments, directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
        }
        try await git(["init", "--initial-branch=main", "--template="])
        let service = GitService(root: root)
        #expect(await service.defaultRemoteURL().flatMap(RemoteWebPage.repository) == nil)
        #expect(await service.remoteURL(named: "origin") == nil)

        // Unreachable hosts: a lookup that touched the network would fail or hang here.
        try await git(["remote", "add", "origin", "git@github.invalid.example:owner/repo.git"])
        try await git(["remote", "add", "fork", "https://user:secret@gitlab.com/me/repo.git"])
        #expect(
            await service.defaultRemoteURL().flatMap(RemoteWebPage.repository)?.absoluteString
                == "https://github.invalid.example/owner/repo")
        let fork = await service.remoteURL(named: "fork")
        #expect(fork?.contains("secret") == false)
        #expect(fork.flatMap(RemoteWebPage.repository)?.absoluteString == "https://gitlab.com/me/repo")
        #expect(await service.remoteURL(named: "--upload-pack=x") == nil)
        #expect(await service.remoteURL(named: "missing") == nil)
        let all = await service.remoteURLs()
        #expect(Set(all.keys) == ["origin", "fork"])
        #expect(all["fork"]?.contains("secret") == false)
        try await git(["config", "url.git@github.com:.insteadOf", "gh:"])
        try await git(["remote", "add", "sqligrp", "gh:sqligrp/repo.git"])
        let expanded = await service.remoteURLs()
        #expect(expanded["sqligrp"] == "git@github.com:sqligrp/repo.git")
    }

    @Test func remoteURLsReadRemoteListLines() {
        let text =
            "origin\tgit@github.com:o/r.git (fetch)\norigin\tgit@github.com:o/r.git (push)\n"
            + "my.fork\thttps://gitlab.com/x (fetch)\norigin\thttps://other (fetch)\n"
            + "\tmissing-name (fetch)\nnotab (fetch)\n"
        let urls = GitService.remoteURLs(fromRemoteList: text)
        #expect(urls == ["origin": "git@github.com:o/r.git", "my.fork": "https://gitlab.com/x"])
        #expect(GitHubRemote.host(of: "git@github-sqligrp:o/r.git") == "github-sqligrp")
        #expect(GitHubRemote.host(of: "/local/path") == nil)
    }
}
