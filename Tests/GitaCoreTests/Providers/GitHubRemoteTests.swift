import Foundation
import Testing

@testable import GitaCore

/// Remotes that reach github.com however they are spelled, and the SSH aliases `ssh -G` resolves.
@Suite("GitHub remote")
struct GitHubRemoteTests {
    @Test(arguments: [
        ("git@github.com:org/repo.git", "org/repo"),
        ("github.com:org/repo", "org/repo"),
        ("ssh://git@github.com/org/repo.git", "org/repo"),
        ("ssh://git@ssh.github.com:443/org/repo.git", "org/repo"),
        ("https://github.com/Org/Repo.git", "Org/Repo"),
        ("http://GitHub.com/org/repo", "org/repo"),
        ("https://octo-cat@github.com/org/repo", "org/repo"),
    ])
    func githubHostsNeedNoLookup(remote: String, nameWithOwner: String) async {
        let runner = DetailRecordingRunner { _ in
            Issue.record("no ssh -G for github.com")
            throw CancellationError()
        }
        let resolved = await GitHubRemoteResolver(runner: runner).resolve(remote)
        #expect(resolved?.repository.nameWithOwner == nameWithOwner)
        #expect(resolved?.webURL?.absoluteString == "https://github.com/" + nameWithOwner)
        #expect(await runner.calls.isEmpty)
    }

    @Test func onlyAnHTTPSLoginIsAHint() {
        #expect(gitHubRemote("https://octo-cat@github.com/org/repo")?.loginHint == GitHubLogin("octo-cat"))
        #expect(gitHubRemote("https://work_emu@github.com/org/repo")?.loginHint == GitHubLogin("work_emu"))
        #expect(gitHubRemote("git@github.com:org/repo.git")?.loginHint == nil)
        #expect(gitHubRemote("https://user:secret@github.com/org/repo")?.loginHint == nil)
        #expect(gitHubRemote("https://-oops@github.com/org/repo")?.loginHint == nil)
        #expect(gitHubRemote("https://ssh.github.com/org/repo") == nil, "ssh.github.com serves SSH only")
    }

    @Test func anAliasResolvesThroughSSHConfiguration() async throws {
        let runner = DetailRecordingRunner { call in
            let host = call.arguments.last == "work" ? "github.com" : "gitlab.example"
            return CommandResult(
                stdout: Data("user git\nhostname \(host)\nport 22\n".utf8), stderr: Data(), exitCode: 0)
        }
        let resolver = GitHubRemoteResolver(runner: runner)
        let work = try #require(await resolver.resolve("work:org/repo.git"))
        #expect(work.sourceID == "github:org/repo")
        #expect(work.loginHint == nil)
        #expect(await resolver.resolve("git@other:org/repo.git") == nil)
        let calls = await runner.calls
        #expect(calls.map(\.executable) == [SSHHostResolver.executable, SSHHostResolver.executable])
        #expect(calls.map(\.arguments) == [["-G", "work"], ["-G", "other"]])
        #expect(calls.allSatisfy { $0.timeout == 3 })
    }

    @Test func otherForgesAndOptionLikeHostsNeverReachSSH() async {
        let runner = DetailRecordingRunner { _ in
            Issue.record("ssh -G must not run")
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let resolver = GitHubRemoteResolver(runner: runner)
        for remote in [
            "git@gitlab.com:org/repo.git", "-oProxyCommand=x:org/repo", "https://example.com/org/repo",
            "/local/path", "file:///org/repo", "https://github.com/org", "git@github.com:org/repo\n--json", "",
        ] {
            #expect(await resolver.resolve(remote) == nil, "\(remote)")
        }
        #expect(await resolver.resolve(nil) == nil)
        #expect(await runner.calls.isEmpty)
    }

    @Test func sshFailureOrAMissingHostNameIsNotGitHub() async {
        let failing = DetailRecordingRunner { _ in CommandResult(stdout: Data(), stderr: Data(), exitCode: 255) }
        #expect(await GitHubRemoteResolver(runner: failing).resolve("work:org/repo") == nil)
        #expect(SSHHostResolver.hostName(in: "user git\nHostName GitHub.com\n") == "github.com")
        #expect(SSHHostResolver.hostName(in: "user git\n") == nil)
    }

    @Test func loginsAreValidatedLikeGh() {
        #expect(GitHubLogin("octo-cat") != nil)
        #expect(GitHubLogin("someone_corp") != nil)
        for invalid in ["", "-x", "a b", "a/b", "a;b", String(repeating: "a", count: 101)] {
            #expect(GitHubLogin(invalid) == nil, "\(invalid)")
        }
        #expect(GitHubLogin("Bob")?.matches("bob") == true)
    }
}
