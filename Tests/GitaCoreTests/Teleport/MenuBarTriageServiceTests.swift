import Foundation
import Testing

@testable import GitaCore

struct MenuBarTriageServiceTests: ProviderDetailFixtures {
    private let root = URL(filePath: "/tmp")
    private let runner = DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data(), exitCode: 0) }

    @Test func accountScopedGitHubCommands() async throws {
        let service = MenuBarTriageService(runner: runner)
        let login = try #require(GitHubLogin("alice"))
        let review = ["pr", "review", "3", "--approve", "--repo", "o/r"]
        for account in [GitHubAccountUse.active, .named(login)] {
            _ = try await service.perform(
                .approvePullRequest(number: 3, owner: "o", repo: "r", repoPath: root, account: account)
            ).get()
        }
        _ = try await service.perform(
            .rerunFailedCIJobs(runID: 17, owner: "o", repo: "r", repoPath: root, account: .active)
        ).get()
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["gh", "/bin/sh", "gh"])
        #expect(
            calls.map(\.arguments) == [
                review, ["-c", GitHubAccountCommand.script, "gita-gh", "alice"] + review,
                ["run", "rerun", "17", "--failed", "--repo", "o/r"],
            ])
        #expect(
            calls.allSatisfy { $0.directory == root && $0.timeout == ProviderCommandExecutor.Limits.action.timeout })
    }

    @Test func linkedVercelActions() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MenuBarTriageService(runner: runner)
        _ = try await service.perform(
            .promoteVercelDeployment(reference: "dpl_one", projectName: "app", scope: "studio", repoPath: root)
        ).get()
        _ = try await service.perform(
            .rollbackVercelDeployment(reference: "dpl_two", projectName: "app", scope: nil, repoPath: root)
        ).get()
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["vercel", "vercel"])
        #expect(
            calls.map(\.arguments) == [
                ["promote", "dpl_one", "--timeout", "0", "--yes", "--non-interactive", "--scope", "studio"],
                ["rollback", "dpl_two", "--timeout", "0", "--yes", "--non-interactive"],
            ])
    }

    @Test func invalidTargetsAndProviderFailures() async {
        let service = MenuBarTriageService(runner: runner)
        for kind: TriageActionKind in [
            .approvePullRequest(number: 0, owner: "x", repo: "y", repoPath: root, account: .active),
            .rerunFailedCIJobs(runID: -1, owner: "x", repo: "y", repoPath: root, account: .active),
            .approvePullRequest(number: 1, owner: "-help", repo: "y", repoPath: root, account: .active),
            .rollbackVercelDeployment(reference: "--help", projectName: "app", scope: nil, repoPath: root),
        ] {
            if case .success = await service.perform(kind) { Issue.record("Accepted invalid action") }
        }
        #expect(await runner.calls.isEmpty)
        let failure = MenuBarTriageService(
            runner: DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data(), exitCode: 1) })
        let result = await failure.perform(
            .approvePullRequest(number: 1, owner: "o", repo: "r", repoPath: root, account: .active))
        guard case .failure(let error) = result else {
            Issue.record("Expected CLI failure")
            return
        }
        #expect(!error.message.isEmpty)
    }
}
