import Foundation
import Testing

@testable import GitaCore

struct TeleportResolverTests: ProviderDetailFixtures {
    private let sha = String(repeating: "a", count: 40)
    private func entry(_ workspace: String, remote: String) -> TeleportRepositoryEntry {
        .init(
            workspaceID: workspace, workspaceTitle: workspace, repoPath: URL(filePath: "/tmp/" + workspace),
            displayName: "Client", remoteURLs: [remote])
    }

    @Test func remoteSelection() async throws {
        let a = entry("Studio", remote: "git@github.com:Org/App.git")
        let b = entry("Home", remote: "git@gh-personal:org/app.git")
        let runner = DetailRecordingRunner { call in
            #expect(call.executable == "/usr/bin/ssh" && call.arguments == ["-G", "gh-personal"])
            return .init(stdout: Data("hostname github.com\n".utf8), stderr: Data(), exitCode: 0)
        }
        let resolver = TeleportResolver(runner: runner)
        let raw = "https://github.com/org/app/pull/4"
        guard case .ambiguous(let choices) = try await resolver.resolve(raw, in: [a, b, a]) else {
            Issue.record("Expected two workspaces")
            return
        }
        #expect(choices.map(\.workspaceID) == ["Studio", "Home"])
        #expect(choices.allSatisfy { $0.matchReason == .githubRemote })
        let filtered = try await resolver.resolve("gita://open?workspace=Home&repo=org/app&pr=4", in: [a, b])
        guard case .resolved(let match) = filtered else {
            Issue.record("Expected Home")
            return
        }
        #expect(match.workspaceID == "Home")
        let hinted = try await resolver.resolve("gita://open?repo=Client&workspace=Studio&run=8", in: [a, b])
        guard case .resolved(let run) = hinted else {
            Issue.record("Expected workspace run")
            return
        }
        #expect(run.matchReason == .workspaceHint)
        #expect(run.target == .workflowRun(runID: 8, jobID: nil, owner: "Org", repo: "App", url: nil))
    }

    @Test func localObjectsAndRemoteBranches() async throws {
        let a = entry("Local", remote: "")
        let runner = DetailRecordingRunner { [sha] call in
            #expect(call.executable == "git")
            #expect(call.arguments.dropLast() == ["--no-optional-locks", "rev-parse", "--verify", "--quiet"])
            let ok = ["aaaaaaa^{commit}", "refs/remotes/origin/topic"].contains(call.arguments.last)
            return .init(stdout: Data((ok ? sha + "\n" : "").utf8), stderr: Data(), exitCode: ok ? 0 : 1)
        }
        let resolver = TeleportResolver(runner: runner)
        guard case .resolved(let commit) = try await resolver.resolve("aaaaaaa", in: [a]) else {
            Issue.record("Expected a commit")
            return
        }
        #expect(commit.target == .commit(sha: sha, url: nil) && commit.matchReason == .localObject)
        for name in ["topic", "origin/topic"] {
            guard case .resolved(let branch) = try await resolver.resolve(name, in: [a]) else {
                Issue.record("Expected a branch")
                return
            }
            #expect(branch.target == .branch(name: name) && branch.matchReason == .localBranch)
        }
        let parsed = try #require(TeleportParser.parse("unseen"))
        #expect(try await resolver.resolve(parsed, in: [a]) == .notFound(parsed))
        #expect(try await resolver.resolve("push changes", in: [a]) == nil)
    }

    @Test func linkedProject() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = TeleportRepositoryEntry(
            workspaceID: "w", workspaceTitle: "Work", repoPath: root, displayName: "Checkout")
        let known = TeleportRepositoryEntry(
            workspaceID: "w", workspaceTitle: "Work", repoPath: root, displayName: "Checkout",
            vercelProjectName: "my-app", vercelTeamSlug: "studio")
        let resolver = TeleportResolver()
        for (raw, repo) in [("https://vercel.com/studio/prj_one/dpl_A", linked), ("https://my-app.vercel.app", known)] {
            guard case .resolved(let match) = try await resolver.resolve(raw, in: [repo]) else {
                Issue.record("Expected project match")
                continue
            }
            #expect(match.matchReason == .vercelProject)
        }
        let metadata = #"{"orgId":"team_one","projectId":"prj_one","projectName":"my-app"}"#
        try Data(metadata.utf8).write(to: root.appendingPathComponent(".vercel/project.json"))
        let named = try await resolver.resolve("https://vercel.com/studio/my-app/dpl_A", in: [linked])
        guard case .resolved(let byName) = named else {
            Issue.record("Expected project.json name")
            return
        }
        #expect(byName.repoPath == root && byName.matchReason == .vercelProject)
        let other = try #require(TeleportParser.parse("https://vercel.com/other/my-app/dpl_A"))
        #expect(try await resolver.resolve(other, in: [known]) == .notFound(other))
    }
}
