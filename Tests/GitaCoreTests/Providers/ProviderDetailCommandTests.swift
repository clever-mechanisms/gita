import Foundation
import XCTest

@testable import GitaCore

/// The provider detail reads as commands: which CLI calls they make, and what a failed call leaves.
final class ProviderDetailCommandTests: XCTestCase, ProviderDetailFixtures {
    @MainActor
    func testSummaryUsesBoundedAllStateAggregateQueryWithExplicitVariables() async {
        let prs = summary([pr()])
        let runner = DetailRecordingRunner { call in
            .init(stdout: call.arguments.first == "run" ? Data("[]".utf8) : prs, stderr: Data(), exitCode: 0)
        }
        let listing = await ProviderService(runner: runner).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: "https://github.com/org/repo.git",
            remote: gitHubRemote("https://github.com/org/repo.git"), choice: nil)
        let report = listing.report
        XCTAssertEqual(report.status, .connected)
        let calls = await runner.calls
        let args = calls.first { $0.arguments.contains("graphql") }!.arguments
        XCTAssertEqual(
            args,
            [
                "api", "graphql", "--hostname", "github.com", "--method", "POST", "-f",
                "query=" + GitHubQueries.pullRequestSummaries, "-f", "owner=org", "-f", "name=repo",
            ])
        XCTAssertTrue(GitHubQueries.pullRequestSummaries.contains("first:30"))
        XCTAssertFalse(GitHubQueries.pullRequestSummaries.contains("states:"))
        XCTAssertFalse(GitHubQueries.pullRequestSummaries.contains("contexts"))
        XCTAssertFalse(GitHubQueries.pullRequestSummaries.contains("reviews"))
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 20 && $0.outputLimit == 2 * 1024 * 1024 })
    }

    @MainActor
    func testPRDetailUsesOneBoundedQueryWithoutBodiesOrLogs() async {
        let payload = detail(pr())
        let runner = DetailRecordingRunner { _ in .init(stdout: payload, stderr: Data(), exitCode: 0) }
        let target = ProviderTarget.pullRequest(repository: "org/repo", number: 42)
        let report = await ProviderService(runner: runner).details(
            root: URL(fileURLWithPath: "/tmp"), target: target, githubAccount: .active)
        XCTAssertEqual(report.status, .connected)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Array(calls[0].arguments.suffix(2)), ["-F", "number=42"])
        XCTAssertTrue(calls[0].arguments.contains("owner=org"))
        XCTAssertTrue(GitHubQueries.pullRequestDetail.contains("latestReviews(first:50)"))
        XCTAssertTrue(GitHubQueries.pullRequestDetail.contains("contexts(first:50)"))
        XCTAssertTrue(GitHubQueries.pullRequestDetail.contains("reviewRequests(first:50)"))
        XCTAssertFalse(GitHubQueries.pullRequestDetail.contains("body"))
        XCTAssertFalse(GitHubQueries.pullRequestDetail.contains("logs"))
        XCTAssertFalse(calls[0].arguments.contains("--paginate"))
    }

    @MainActor
    func testGraphQLExitOnePreservesValidatedPartialDataOnly() async {
        var row = pr()
        row["latestReviews"] = NSNull()
        let payload = detail(row, errors: true)
        let runner = DetailRecordingRunner { _ in
            .init(stdout: payload, stderr: Data("private-error-detail".utf8), exitCode: 1)
        }
        let report = await ProviderService(runner: runner).details(
            root: URL(fileURLWithPath: "/tmp"), target: .pullRequest(repository: "org/repo", number: 42),
            githubAccount: .active)
        XCTAssertEqual(report.status, .partial)
        guard case .pullRequest(let detail) = report.content else {
            XCTFail("Verified partial metadata must survive GraphQL errors")
            return
        }
        XCTAssertEqual(detail.title, "Ship")
        XCTAssertNil(detail.reviews.total)
        XCTAssertFalse(report.diagnostic?.contains("private-error-detail") ?? true)
        let mismatch = await ProviderService(runner: runner).details(
            root: URL(fileURLWithPath: "/tmp"), target: .pullRequest(repository: "other/repo", number: 42),
            githubAccount: .active)
        XCTAssertNil(mismatch.content)
        let withoutErrors = self.detail(pr())
        let unexpectedExit = DetailRecordingRunner { _ in .init(stdout: withoutErrors, stderr: Data(), exitCode: 1) }
        let rejected = await ProviderService(runner: unexpectedExit).details(
            root: URL(fileURLWithPath: "/tmp"), target: .pullRequest(repository: "org/repo", number: 42),
            githubAccount: .active)
        XCTAssertNil(rejected.content)
    }

    @MainActor
    func testWorkflowUsesScalarRunAndExplicitAttemptJobsGET() async {
        let runData = json(runFixture())
        let jobData = json(["total_count": 1, "jobs": [job()]])
        let runner = DetailRecordingRunner { call in
            .init(stdout: call.arguments.first == "run" ? runData : jobData, stderr: Data(), exitCode: 0)
        }
        let report = await ProviderService(runner: runner).details(
            root: URL(fileURLWithPath: "/tmp"), target: .workflowRun(repository: "org/repo", runID: 9, attempt: 3),
            githubAccount: .active)
        XCTAssertEqual(report.status, .connected)
        let calls = await runner.calls
        XCTAssertEqual(
            calls[0].arguments,
            [
                "run", "view", "9", "--repo", "github.com/org/repo", "--attempt", "3", "--json",
                """
                databaseId,number,attempt,displayTitle,workflowName,event,status,conclusion,headSha,headBranch,url,\
                startedAt,updatedAt
                """,
            ])
        XCTAssertEqual(
            calls[1].arguments,
            [
                "api", "--hostname", "github.com", "--method", "GET",
                "repos/org/repo/actions/runs/9/attempts/3/jobs?per_page=50&page=1",
            ])
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 20 && $0.outputLimit == 2 * 1024 * 1024 })
    }

    @MainActor
    func testWorkflowSecondaryFailureKeepsRunButCancellationDoesNot() async {
        let runData = json(runFixture())
        let runner = DetailRecordingRunner { call in
            if call.arguments.first == "run" { return .init(stdout: runData, stderr: Data(), exitCode: 0) }
            return .init(stdout: Data(), stderr: Data("403 credential=DO_NOT_EXPOSE".utf8), exitCode: 1)
        }
        let target = ProviderTarget.workflowRun(repository: "org/repo", runID: 9, attempt: 3)
        let report = await ProviderService(runner: runner).details(
            root: URL(fileURLWithPath: "/tmp"), target: target, githubAccount: .active)
        XCTAssertEqual(report.status, .partial)
        guard case .workflowRun(let detail) = report.content else {
            XCTFail("Run metadata must survive unavailable jobs")
            return
        }
        XCTAssertEqual(detail.runID, 9)
        XCTAssertNil(detail.jobs.total)
        XCTAssertFalse(report.diagnostic?.contains("DO_NOT_EXPOSE") ?? true)
        let cancelled = DetailRecordingRunner { call in
            if call.arguments.first == "run" { return .init(stdout: runData, stderr: Data(), exitCode: 0) }
            throw CancellationError()
        }
        let cancelledReport = await ProviderService(runner: cancelled).details(
            root: URL(fileURLWithPath: "/tmp"), target: target, githubAccount: .active)
        XCTAssertEqual(cancelledReport.status, .cancelled)
        XCTAssertNil(cancelledReport.content)
    }

    @MainActor
    func testFailedDeploymentUsesSuccessfulMetadataGETAndProjectFailureIsPartial() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var row = deployment()
        row["readyState"] = "ERROR"
        let failed = json(row)
        let runner = DetailRecordingRunner { call in
            if call.arguments.first == "api" { return .init(stdout: failed, stderr: Data(), exitCode: 0) }
            return .init(stdout: Data(), stderr: Data("403 token=DO_NOT_EXPOSE".utf8), exitCode: 1)
        }
        let target = ProviderTarget.deployment(reference: "dpl_one", projectName: "demo", scope: "team")
        let report = await ProviderService(runner: runner).details(root: root, target: target, githubAccount: .active)
        XCTAssertEqual(report.status, .partial)
        guard case .deployment(let detail) = report.content else {
            XCTFail("Valid failed deployment must survive")
            return
        }
        XCTAssertEqual(detail.state, .failure)
        XCTAssertNil(detail.project)
        XCTAssertFalse(report.diagnostic?.contains("DO_NOT_EXPOSE") ?? true)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.map(\.arguments),
            [
                [
                    "api", "/v13/deployments/dpl_one?withGitRepoInfo=true", "--method", "GET", "--raw",
                    "--non-interactive", "--scope", "team",
                ], ["project", "inspect", "prj_one", "--json", "--scope", "team", "--non-interactive"],
            ])
        let mismatch = await ProviderService(runner: runner).details(
            root: root, target: .deployment(reference: "dpl_other", projectName: "demo", scope: "team"),
            githubAccount: .active)
        XCTAssertNil(mismatch.content)
        XCTAssertEqual(mismatch.status, .unavailable)
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 20 && $0.outputLimit == 2 * 1024 * 1024 })
        let unexpectedExit = DetailRecordingRunner { _ in .init(stdout: failed, stderr: Data(), exitCode: 1) }
        let rejected = await ProviderService(runner: unexpectedExit).details(
            root: root, target: target, githubAccount: .active)
        XCTAssertNil(rejected.content)
        XCTAssertEqual(rejected.status, .unavailable)
        let rejectedCalls = await unexpectedExit.calls
        XCTAssertEqual(rejectedCalls.count, 1)
    }

    @MainActor
    func testInvalidTargetsNeverLaunchCommands() async {
        let runner = DetailRecordingRunner { _ in
            XCTFail("Invalid identity must not reach a command")
            throw CancellationError()
        }
        let service = ProviderService(runner: runner)
        for target in [
            ProviderTarget.pullRequest(repository: "org/repo?token=bad", number: 1),
            .pullRequest(repository: "org/repo", number: 0), .workflowRun(repository: "org/repo", runID: 9, attempt: 0),
            .deployment(reference: "--help", projectName: "demo", scope: nil),
            .deployment(reference: "demo.vercel.app", projectName: "demo", scope: "--token"),
        ] {
            let report = await service.details(
                root: URL(fileURLWithPath: "/tmp"), target: target, githubAccount: .active)
            XCTAssertEqual(report.status, .unavailable)
            XCTAssertNil(report.content)
        }
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }
}
