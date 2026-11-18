import Foundation
import XCTest

@testable import GitaCore

final class ProviderDetailTests: XCTestCase, ProviderDetailFixtures {
    func testSummaryAggregatePrecedenceAndTypedTargetsWithoutCheckRows() throws {
        for (aggregate, expected) in [
            ("FAILURE", SignalState.failure), ("ERROR", .failure), ("PENDING", .pending), ("SUCCESS", .success),
            ("NEW_STATE", .neutral),
        ] {
            let parsed = try ProviderDetailParsers.pullRequestSummaries(
                summary([pr(checksState: aggregate)]), repository: "org/repo")
            XCTAssertEqual(parsed.value.count, 1)
            XCTAssertEqual(parsed.value[0].state, expected)
            XCTAssertEqual(parsed.value[0].kind, .pullRequest)
            XCTAssertEqual(parsed.value[0].target, .pullRequest(repository: "org/repo", number: 42))
            XCTAssertEqual(parsed.value[0].commit, "head")
        }
        let unknown = try ProviderDetailParsers.pullRequestSummaries(
            summary([pr(checksState: nil)]), repository: "org/repo")
        XCTAssertEqual(unknown.value[0].state, .neutral)
        XCTAssertEqual(unknown.value[0].pullRequest?.status, .init(review: .approved, checks: .unavailable))
        XCTAssertEqual(unknown.value[0].localizedDetail, "Approved · Checks unavailable")
        var merged = pr(checksState: nil)
        merged["state"] = "MERGED"
        let result = try ProviderDetailParsers.pullRequestSummaries(summary([merged]), repository: "org/repo")
        XCTAssertEqual(result.value[0].detail, "Merged")
        var unknownLifecycle = pr()
        unknownLifecycle["state"] = "FUTURE_STATE"
        let future = try ProviderDetailParsers.pullRequestSummaries(summary([unknownLifecycle]), repository: "org/repo")
        XCTAssertEqual(future.value[0].state, .neutral)
        XCTAssertEqual(future.value[0].detail, "Unknown")
    }

    func testSummaryCarriesAuthorshipMergeTimesAndViewerReviewRequests() throws {
        var open = pr()
        open["number"] = 7
        open["createdAt"] = "2026-11-09T10:00:00Z"
        open["author"] = ["login": "chrisstampar"]
        open["reviewRequests"] = connection([
            ["requestedReviewer": ["__typename": "User", "login": "Me-Login"]],
            ["requestedReviewer": ["__typename": "Team"]], ["requestedReviewer": NSNull()],
        ])
        var merged = pr()
        merged["number"] = 8
        merged["state"] = "MERGED"
        merged["mergedAt"] = "2026-11-09T12:30:00.5Z"
        merged["mergedBy"] = ["login": "rolottr"]
        merged["author"] = ["login": "dependabot[bot]"]
        merged["reviewRequests"] = connection([["requestedReviewer": ["__typename": "User", "login": "me-login"]]])
        var anonymous = pr()
        anonymous["number"] = 9
        anonymous["author"] = NSNull()
        anonymous["mergedBy"] = ["login": "x"]
        anonymous["createdAt"] = "0001-01-01T00:00:00Z"
        anonymous["mergedAt"] = "2026-11-09T12:30:00Z"
        var otherReviewer = pr()
        otherReviewer["number"] = 10
        otherReviewer["reviewRequests"] = connection([
            ["requestedReviewer": ["__typename": "User", "login": "someone-else"]]
        ])
        var spoofed = pr()
        spoofed["number"] = 11
        spoofed["author"] = ["login": "bad login\n"]
        let data = json([
            "data": [
                "viewer": ["login": "me-login"],
                "repository": [
                    "nameWithOwner": "org/repo",
                    "pullRequests": connection([open, merged, anonymous, otherReviewer, spoofed]),
                ],
            ]
        ])
        let items = try ProviderDetailParsers.pullRequestSummaries(data, repository: "org/repo").value
        let summaries = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in item.pullRequest.map { ($0.number, $0) } })
        XCTAssertEqual(summaries[7]?.author, "chrisstampar")
        XCTAssertEqual(summaries[7]?.createdAt, ISO8601DateFormatter().date(from: "2026-11-09T10:00:00Z"))
        XCTAssertEqual(summaries[7]?.reviewRequestedFromViewer, true, "viewer match is case-insensitive")
        XCTAssertNil(summaries[7]?.mergedBy, "an open PR never reports a merger")
        XCTAssertNil(summaries[7]?.mergedAt)
        XCTAssertEqual(summaries[8]?.mergedBy, "rolottr")
        XCTAssertEqual(summaries[8]?.author, "dependabot[bot]")
        XCTAssertNotNil(summaries[8]?.mergedAt, "fractional seconds parse")
        XCTAssertEqual(summaries[8]?.reviewRequestedFromViewer, false, "a merged PR no longer asks for review")
        XCTAssertNil(summaries[9]?.author, "deleted users stay unknown")
        XCTAssertNil(summaries[9]?.createdAt, "zero dates stay absent")
        XCTAssertNil(summaries[9]?.mergedBy, "merge facts need the MERGED lifecycle")
        XCTAssertEqual(summaries[10]?.reviewRequestedFromViewer, false)
        XCTAssertNil(summaries[11]?.author, "non-login text is rejected")
        XCTAssertEqual(ProviderDetailParsers.viewerLogin(data), "me-login")
        // Without a viewer the request flag stays false instead of guessing.
        let noViewer = try ProviderDetailParsers.pullRequestSummaries(summary([open]), repository: "org/repo").value
        XCTAssertEqual(noViewer.first?.pullRequest?.reviewRequestedFromViewer, false)
        XCTAssertEqual(noViewer.first?.pullRequest?.author, "chrisstampar")
    }

    @MainActor
    func testSummaryRequestRemembersViewerWithoutASecondCall() async {
        let prs = json([
            "data": [
                "viewer": ["login": "octo-viewer"],
                "repository": ["nameWithOwner": "org/repo", "pullRequests": connection([pr()])],
            ]
        ])
        let runner = DetailRecordingRunner { call in
            .init(stdout: call.arguments.first == "run" ? Data("[]".utf8) : prs, stderr: Data(), exitCode: 0)
        }
        let listing = await ProviderService(runner: runner).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: "https://github.com/org/repo.git",
            remote: gitHubRemote("https://github.com/org/repo.git"), choice: nil)
        let report = listing.report
        XCTAssertEqual(report.status, .connected)
        XCTAssertEqual(listing.viewerLogin, "octo-viewer")
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2, "one run list and one GraphQL request per refresh")
        XCTAssertFalse(calls.contains { $0.arguments.contains("user") })
        for field in [
            "viewer { login }", "author { login }", "createdAt", "mergedAt", "mergedBy { login }",
            "reviewRequests(first:10)",
        ] {
            XCTAssertTrue(GitHubQueries.pullRequestSummaries.contains(field), field)
        }
    }

    func testSummaryNeverReusesOldHeadChecksAndEnforcesThirtyRows() throws {
        var row = pr()
        row["headRefOid"] = "new-head"
        let mismatch = try ProviderDetailParsers.pullRequestSummaries(summary([row]), repository: "org/repo")
        XCTAssertTrue(mismatch.partial)
        XCTAssertEqual(mismatch.value[0].state, .neutral)
        let rows = (1...31).map { number in
            var row = pr()
            row["number"] = number
            return row
        }
        let bounded = try ProviderDetailParsers.pullRequestSummaries(summary(rows), repository: "org/repo")
        XCTAssertEqual(bounded.value.count, 30)
        XCTAssertTrue(bounded.partial)
        XCTAssertThrowsError(
            try ProviderDetailParsers.pullRequestSummaries(
                summary([pr()], repository: "other/repo"), repository: "org/repo"))
        XCTAssertThrowsError(
            try ProviderDetailParsers.pullRequestSummaries(
                json(["errors": [["message": "private diagnostic"]]]), repository: "org/repo"))
        let missingCoverage = json([
            "data": ["repository": ["nameWithOwner": "org/repo", "pullRequests": ["nodes": []]]]
        ])
        XCTAssertTrue(try ProviderDetailParsers.pullRequestSummaries(missingCoverage, repository: "org/repo").partial)
    }

    func testPRChecksUseProviderIdentityWhenNamesAndURLsOverlap() throws {
        let checks: [[String: Any]] = [
            [
                "__typename": "CheckRun", "id": "check-linux", "name": "Build", "status": "COMPLETED",
                "conclusion": "SKIPPED", "detailsUrl": "https://ci.example.test/dashboard",
                "checkSuite": ["workflowRun": ["workflow": ["name": "Linux"]]],
            ],
            [
                "__typename": "CheckRun", "id": "check-mac", "name": "Build", "status": "IN_PROGRESS",
                "detailsUrl": "https://ci.example.test/dashboard",
                "checkSuite": ["workflowRun": ["workflow": ["name": "Mac"]]],
            ],
            [
                "__typename": "StatusContext", "id": "context-deploy", "context": "Deploy", "state": "ERROR",
                "targetUrl": "https://ci.example.test/dashboard",
            ],
        ]
        let before = try ProviderDetailParsers.pullRequest(
            detail(pr(checks: checks)), repository: "org/repo", number: 42
        ).value
        let after = try ProviderDetailParsers.pullRequest(
            detail(pr(checks: checks.reversed())), repository: "org/repo", number: 42
        ).value
        XCTAssertEqual(Set(before.checks.items.map(\.id)).count, 3)
        XCTAssertEqual(before.checks.items[0].id, after.checks.items[2].id)
        XCTAssertEqual(before.checks.items[0].state, .neutral)
        XCTAssertEqual(before.checks.items[0].workflow, "Linux")
        XCTAssertEqual(before.checks.items[2].state, .failure)
    }

    func testPRPaginationDeletedReviewAuthorsAndTeamRequestsAreTruthful() throws {
        var row = pr()
        row["latestReviews"] = connection(
            [
                [
                    "id": "review-1", "author": NSNull(), "state": "APPROVED", "commit": ["oid": "old-head"],
                    "body": "MUST NOT MODEL",
                ],
                ["id": "review-2", "author": ["login": "reviewer"], "state": "DISMISSED"],
            ], total: 70, more: true, cursor: "review-page-1")
        row["reviewRequests"] = connection([
            [
                "requestedReviewer": [
                    "__typename": "Team", "id": "team-1", "slug": "quality", "organization": ["login": "org"],
                ]
            ],
            ["requestedReviewer": ["__typename": "Bot", "id": "bot-1", "login": "review-bot"]],
            ["requestedReviewer": NSNull()],
        ])
        let parsed = try ProviderDetailParsers.pullRequest(detail(row), repository: "org/repo", number: 42)
        XCTAssertTrue(parsed.partial)
        XCTAssertNil(parsed.value.reviews.items[0].author)
        XCTAssertEqual(parsed.value.reviews.items[0].status, .approved)
        XCTAssertEqual(parsed.value.reviews.total, 70)
        XCTAssertTrue(parsed.value.reviews.hasMore)
        XCTAssertEqual(parsed.value.requestedReviewers.items.map(\.name), ["org/quality", "review-bot"])
        XCTAssertFalse(parsed.value.requestedReviewers.hasMore)
        XCTAssertEqual(parsed.value.requestedReviewers.total, 3)
    }

    func testPRUnknownRollupAndGraphQLPartialErrorsKeepMetadataWithoutGreenChecks() throws {
        var row = pr(checksState: nil)
        row["latestReviews"] = NSNull()
        let parsed = try ProviderDetailParsers.pullRequest(
            detail(row, errors: true), repository: "org/repo", number: 42)
        XCTAssertTrue(parsed.partial)
        XCTAssertEqual(parsed.value.title, "Ship")
        XCTAssertNil(parsed.value.checks.total)
        XCTAssertNil(parsed.value.reviews.total)
        XCTAssertTrue(parsed.value.checks.items.isEmpty)
        XCTAssertThrowsError(try ProviderDetailParsers.pullRequest(detail(pr()), repository: "org/repo", number: 43))
    }

    func testPRConnectionsEnforceFiftyAndKeepKnownEmptySeparateFromUnknown() throws {
        let checks = (1...51).map {
            ["__typename": "StatusContext", "id": "check-\($0)", "context": "Build", "state": "SUCCESS"]
        }
        let parsed = try ProviderDetailParsers.pullRequest(
            detail(pr(checks: checks)), repository: "org/repo", number: 42)
        XCTAssertEqual(parsed.value.checks.items.count, 50)
        XCTAssertEqual(parsed.value.checks.total, 51)
        XCTAssertTrue(parsed.value.checks.hasMore)
        XCTAssertTrue(parsed.partial)
        let empty = try ProviderDetailParsers.pullRequest(detail(pr()), repository: "org/repo", number: 42)
        XCTAssertEqual(empty.value.checks.total, 0)
        XCTAssertFalse(empty.partial)
    }

    func testRunSummaryCarriesActualAttemptAndRefusesToInventOne() throws {
        let items = try ProviderParsers.githubRuns(
            json([runFixture(), ["databaseId": 10, "status": "queued"]]), repository: "org/repo")
        XCTAssertEqual(items[0].target, .workflowRun(repository: "org/repo", runID: 9, attempt: 3))
        XCTAssertEqual(items[0].kind, .workflowRun)
        XCTAssertEqual(items[0].title, "#17 Ship")
        XCTAssertEqual(items[0].category, "CI")
        XCTAssertNil(items[1].target)
        XCTAssertEqual(items[1].title, "Workflow")
    }

    func testWorkflowRejectsStaleAttemptAndBoundsJobsAndSteps() throws {
        let model = try ProviderDetailParsers.workflowRun(
            json(runFixture()), repository: "org/repo", runID: 9, attempt: 3)
        XCTAssertThrowsError(
            try ProviderDetailParsers.workflowRun(json(runFixture()), repository: "org/repo", runID: 9, attempt: 2))
        XCTAssertThrowsError(
            try ProviderDetailParsers.workflowRun(
                json(runFixture()), repository: "elsewhere/repo", runID: 9, attempt: 3))
        let steps = (1...201).map {
            [
                "number": $0, "name": "Step", "status": "completed", "conclusion": "success",
                "started_at": "0001-01-01T00:00:00Z",
            ] as [String: Any]
        }
        let jobs = (1...51).map { id in job(id: Int64(id), steps: steps) }
        let page = try ProviderDetailParsers.workflowJobs(json(["total_count": 80, "jobs": jobs]), run: model)
        XCTAssertEqual(page.items.count, 50)
        XCTAssertEqual(page.total, 80)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items[0].steps.count, 200)
        XCTAssertTrue(page.items[0].stepsTruncated)
        var wrong = job()
        wrong["run_attempt"] = 2
        XCTAssertThrowsError(
            try ProviderDetailParsers.workflowJobs(json(["total_count": 1, "jobs": [wrong]]), run: model))
        wrong = job()
        wrong["head_sha"] = "old-head"
        XCTAssertThrowsError(
            try ProviderDetailParsers.workflowJobs(json(["total_count": 1, "jobs": [wrong]]), run: model))
        XCTAssertThrowsError(
            try ProviderDetailParsers.workflowJobs(json(["total_count": 0, "jobs": [job()]]), run: model))
    }

    func testVercelTargetsUseScopeAndCustomEnvironmentAndRejectUnsafeReferences() throws {
        let rows = try ProviderParsers.vercelDeployments(
            json([
                "contextName": "team",
                "deployments": [
                    [
                        "id": "dpl_one", "name": "demo", "url": "demo-one.vercel.app", "state": "READY",
                        "customEnvironment": ["slug": "staging"],
                    ]
                ],
            ]))
        XCTAssertEqual(rows[0].kind, .deployment)
        XCTAssertEqual(rows[0].target, .deployment(reference: "dpl_one", projectName: "demo", scope: "team"))
        XCTAssertEqual(rows[0].detail, "staging · Ready")
        for reference in [
            "--help", "https://user:password@example.test", "https://example.test/path",
            "https://example.test?token=private", "bad_host.example.test", "example.test\n--json",
        ] {
            XCTAssertNil(ProviderDetailParsers.deploymentReference(reference), reference)
        }
    }

    func testDeploymentIdentityAndAllowedMetadata() throws {
        var row = deployment()
        row["target"] = "staging"
        row["duration"] = ["timeToReady": 1250]
        row["alias"] = ["demo.example.test", "https://user:password@bad.example.test"]
        row["env"] = ["PRIVATE_KEY": "NEVER MODEL"]
        let parsed = try ProviderDetailParsers.deployment(
            json(row), reference: "demo-one.vercel.app", projectName: "demo", scope: "team")
        XCTAssertEqual(parsed.durationMilliseconds, 1250)
        XCTAssertEqual(parsed.aliases.map(\.absoluteString), ["https://demo.example.test"])
        XCTAssertNil(parsed.commit)
        XCTAssertNil(parsed.dashboardURL)
        XCTAssertThrowsError(
            try ProviderDetailParsers.deployment(json(row), reference: "dpl_other", projectName: "demo", scope: "team"))
        XCTAssertThrowsError(
            try ProviderDetailParsers.deployment(json(row), reference: "dpl_one", projectName: "other", scope: "team"))
        XCTAssertThrowsError(
            try ProviderDetailParsers.deployment(
                json(row), reference: "dpl_one", projectName: "demo", scope: "other-team"))
        let project = try ProviderDetailParsers.deploymentProject(
            json([
                "id": "prj_one", "name": "demo", "owner": ["slug": "team"], "framework": "nextjs",
                "env": ["secret": "NEVER MODEL"],
            ]), projectID: "prj_one", scope: "team")
        XCTAssertEqual(project.framework, "nextjs")
    }

    func testDeploymentAPIEnvironmentGitSourceAndIgnoredPrivateFields() throws {
        var row = deployment()
        row["target"] = NSNull()
        row["gitSource"] = ["sha": "current-head", "ref": "feature", "commitMetadata": ["message": "IGNORE THIS"]]
        row["meta"] = ["githubCommitSha": "older-meta", "githubCommitRef": "older-branch"]
        row["errorMessage"] = "Build could not complete"
        row["env"] = ["PRIVATE_VARIABLE_NAME"]
        row["services"] = ["private": ["env": ["PRIVATE_REFERENCE": ["service": "private", "type": "reference"]]]]
        row["oidcTokenClaims"] = ["private": "IGNORE THIS"]
        row["builds"] = ["unmodeled": "IGNORED REGARDLESS OF SHAPE"]
        func parse(_ row: [String: Any]) throws -> DeploymentDetail {
            try ProviderDetailParsers.deployment(json(row), reference: "dpl_one", projectName: "demo", scope: "team")
        }
        let preview = try parse(row)
        XCTAssertEqual(preview.commit, "current-head")
        XCTAssertEqual(preview.branch, "feature")
        XCTAssertEqual(preview.reason, "Build could not complete")
        row["customEnvironment"] = ["slug": "qa"]
        row.removeValue(forKey: "target")
        row.removeValue(forKey: "customEnvironment")
        row.removeValue(forKey: "gitSource")
        XCTAssertEqual(try parse(row).commit, "older-meta")
        row["readyState"] = "BLOCKED"
        XCTAssertEqual(try parse(row).state, .failure)
        row["team"] = ["slug": "different-team"]
        XCTAssertThrowsError(try parse(row))
    }

    @MainActor
    func testDeploymentAPIHostnameKeepsBoundsAndNeverFallsBackToBuildEnrichment() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DetailRecordingRunner { _ in throw CommandError.outputLimitExceeded(2 * 1024 * 1024) }
        let report = await ProviderService(runner: runner).details(
            root: root,
            target: .deployment(reference: "https://demo-one.vercel.app", projectName: "demo", scope: nil),
            githubAccount: .active)
        XCTAssertEqual(report.status, .responseTooLarge)
        XCTAssertNil(report.content)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].arguments,
            [
                "api", "/v13/deployments/demo-one.vercel.app?withGitRepoInfo=true", "--method", "GET", "--raw",
                "--non-interactive",
            ])
        XCTAssertEqual(calls[0].outputLimit, 2 * 1024 * 1024)
        XCTAssertEqual(calls[0].timeout, 20)
    }

    @MainActor
    func testDeploymentProjectIDAllowsRenameButRejectsReusedName() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var row = deployment()
        row["projectId"] = "prj_original"
        row["project"] = ["id": "prj_original", "name": "historical-name"]
        let payload = json(row)
        let target = ProviderTarget.deployment(reference: "dpl_one", projectName: "demo", scope: "team")
        for (returnedID, currentName, expectedStatus) in [
            ("prj_original", "renamed-demo", ProviderStatus.connected), ("prj_replacement", "demo", .partial),
        ] {
            let project = json([
                "id": returnedID, "name": currentName, "owner": ["slug": "team"], "framework": "nextjs",
            ])
            let runner = DetailRecordingRunner { call in
                .init(stdout: call.arguments.first == "api" ? payload : project, stderr: Data(), exitCode: 0)
            }
            let report = await ProviderService(runner: runner).details(
                root: root, target: target, githubAccount: .active)
            XCTAssertEqual(report.status, expectedStatus)
            guard case .deployment(let detail) = report.content else {
                XCTFail("Deployment metadata must remain available")
                return
            }
            XCTAssertEqual(detail.projectID, "prj_original")
            XCTAssertEqual(detail.projectName, "demo")
            if returnedID == "prj_original" {
                XCTAssertEqual(detail.project?.name, "renamed-demo")
            } else {
                XCTAssertNil(detail.project)
            }
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(
                calls[1].arguments,
                ["project", "inspect", "prj_original", "--json", "--scope", "team", "--non-interactive"])
        }
    }

    @MainActor
    func testMissingInvalidOrInconsistentProjectIDKeepsDeploymentPartialWithoutProjectLookup() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var missing = deployment()
        missing.removeValue(forKey: "projectId")
        var invalid = deployment()
        invalid["projectId"] = "--help"
        var inconsistent = deployment()
        inconsistent["project"] = ["id": "prj_replacement"]
        var onlyEmbedded = missing
        onlyEmbedded["project"] = ["id": "prj_one"]
        for row in [missing, invalid, inconsistent, onlyEmbedded] {
            let payload = json(row)
            let runner = DetailRecordingRunner { call in
                XCTAssertEqual(
                    call.arguments.first, "api", "An unverified project identity must never trigger a name lookup")
                return .init(stdout: payload, stderr: Data(), exitCode: 0)
            }
            let report = await ProviderService(runner: runner).details(
                root: root,
                target: .deployment(reference: "dpl_one", projectName: "demo", scope: "team"), githubAccount: .active)
            XCTAssertEqual(report.status, .partial)
            guard case .deployment(let detail) = report.content else {
                XCTFail("Deployment metadata must survive missing project identity")
                return
            }
            XCTAssertEqual(detail.id, "dpl_one")
            XCTAssertNil(detail.projectID)
            XCTAssertNil(detail.project)
            let calls = await runner.calls
            XCTAssertEqual(calls.count, 1)
        }
    }
}
