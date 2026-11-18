import Foundation
import XCTest

@testable import GitaCore

/// Shapes mirror the 2026-11-09 read-only observations (key names only; values invented).
final class VercelContextTests: XCTestCase {
    private let live = String(repeating: "a", count: 40), older = String(repeating: "b", count: 40),
        newest = String(repeating: "c", count: 40)

    private func project(
        target: String = "dpl_new", host: String = "demo-new-team.vercel.app", sha: String? = nil,
        aliasRequest: String = "null"
    ) -> Data {
        Data(
            """
            {"id":"prj_one","name":"demo","env":[{"key":"SECRET","value":"x"}],"link":{"type":"github",\
            "productionBranch":"main"},
             "targets":{"production":{"id":"\(target)","url":"\(host)","alias":["demo.dev","www.demo.dev","demo-team.vercel.app","demo-git-main-team.vercel.app"],
               "meta":{"githubCommitSha":"\(sha ?? newest)","githubCommitRef":"main","githubCommitRepoId":12},"readyState":"READY","createdAt":1794236091023,
               "oidcTokenClaims":{"sub":"x"},"builds":[]}},
             "lastAliasRequest":\(aliasRequest)}
            """.utf8)
    }
    private func aliases(production: String, productionHost: String) -> Data {
        Data(
            """
            {"aliases":[
              {"alias":"demo.dev","deploymentId":"\(production)","deployment":{"id":"\(production)","url":"\(productionHost)"}},
              {"alias":"www.demo.dev","deploymentId":"\(production)","deployment":{"id":"\(production)","url":"\(productionHost)"}},
              {"alias":"demo-team.vercel.app","deploymentId":"\(production)","deployment":{"id":"\(production)","url":"\(productionHost)"}},
              {"alias":"demo-git-main-team.vercel.app","deploymentId":"dpl_new","deployment":{"id":"dpl_new",\
            "url":"demo-new-team.vercel.app"}},
              {"alias":"demo-git-feature-team.vercel.app","deploymentId":"dpl_feat","deployment":{"id":"dpl_feat",\
            "url":"demo-feat-team.vercel.app"}}
            ],"pagination":{"count":5,"next":null}}
            """.utf8)
    }
    private var items: [ProviderItem] {
        [
            ProviderItem(
                id: "vercel:demo-new-team.vercel.app", provider: .vercel, category: "Deployment", title: "demo",
                state: .success, commit: newest, branch: "main",
                url: URL(string: "https://demo-new-team.vercel.app"), date: Date(timeIntervalSince1970: 1_794_236_091),
                kind: .deployment,
                target: .deployment(reference: "demo-new-team.vercel.app", projectName: "demo", scope: "team"),
                deployment: DeploymentSummary(environment: .production)),
            ProviderItem(
                id: "vercel:demo-old-team.vercel.app", provider: .vercel, category: "Deployment", title: "demo",
                state: .success, commit: older, branch: "main",
                url: URL(string: "https://demo-old-team.vercel.app"), date: Date(timeIntervalSince1970: 1_794_000_000),
                kind: .deployment,
                target: .deployment(reference: "demo-old-team.vercel.app", projectName: "demo", scope: "team"),
                deployment: DeploymentSummary(environment: .production)),
            ProviderItem(
                id: "vercel:demo-feat-team.vercel.app", provider: .vercel, category: "Deployment", title: "demo",
                state: .failure, commit: live, branch: "feature",
                url: URL(string: "https://demo-feat-team.vercel.app"), kind: .deployment,
                target: .deployment(reference: "demo-feat-team.vercel.app", projectName: "demo", scope: "team"),
                deployment: DeploymentSummary(environment: .preview)),
        ]
    }

    func testLiveProductionFollowsTheProductionTargetWhenDomainsPointAtIt() throws {
        let parsed = try VercelContextParsers.project(project(), projectID: "prj_one")
        let context = VercelContextParsers.context(
            project: parsed,
            aliases: try VercelContextParsers.aliases(
                aliases(production: "dpl_new", productionHost: "demo-new-team.vercel.app")),
            comments: nil, items: items)
        XCTAssertEqual(context.productionBranch, "main")
        XCTAssertEqual(context.production?.deploymentID, "dpl_new")
        XCTAssertEqual(context.production?.commit, newest)
        XCTAssertEqual(context.production?.isPinned, false)
        XCTAssertEqual(context.production?.domains.map(\.host), ["demo.dev", "www.demo.dev", "demo-team.vercel.app"])
        XCTAssertTrue(context.isLive(items[0]))
        XCTAssertFalse(context.isLive(items[1]))
        XCTAssertEqual(context.branchPreviews["feature"]?.host, "demo-git-feature-team.vercel.app")
        XCTAssertEqual(context.branchPreviews["main"]?.host, "demo-git-main-team.vercel.app")
    }

    /// Open goes to the address people use, never the per-deployment host when a stable one serves the same build.
    func testOpenUsesTheProductionDomainOrTheBranchURLThatServesTheDeployment() throws {
        let parsed = try VercelContextParsers.project(project(), projectID: "prj_one")
        let context = VercelContextParsers.context(
            project: parsed,
            aliases: try VercelContextParsers.aliases(
                aliases(production: "dpl_new", productionHost: "demo-new-team.vercel.app")),
            comments: nil, items: items)
        XCTAssertEqual(context.primaryURL(for: items[0])?.host, "demo.dev", "live: the production domain")
        XCTAssertEqual(
            context.primaryURL(for: items[1])?.host, "demo-old-team.vercel.app",
            "an older build: only its own host shows it")
        XCTAssertEqual(
            context.primaryURL(for: items[2])?.host, "demo-git-feature-team.vercel.app",
            "the branch URL serves this preview")

        // After a rollback the old build is live and the branch URL still serves the newer one.
        let rolledBack = VercelContextParsers.context(
            project: try VercelContextParsers.project(
                project(aliasRequest: #"{"toDeploymentId":"dpl_old","jobStatus":"succeeded","type":"rollback"}"#),
                projectID: "prj_one"),
            aliases: try VercelContextParsers.aliases(
                aliases(production: "dpl_old", productionHost: "demo-old-team.vercel.app")), comments: nil, items: items
        )
        XCTAssertEqual(rolledBack.primaryURL(for: items[1])?.host, "demo.dev")
        XCTAssertEqual(rolledBack.primaryURL(for: items[0])?.host, "demo-git-main-team.vercel.app")

        let production = VercelContext.Production(
            deploymentID: "dpl_x",
            domains: [URL(string: "https://demo-team.vercel.app")!, URL(string: "https://demo.dev")!])
        XCTAssertEqual(production.primaryDomain?.host, "demo.dev", "a custom domain before the .vercel.app alias")
    }

    func testRolledBackProductionIsWhatTheDomainsServeNotTheLatestTarget() throws {
        let parsed = try VercelContextParsers.project(
            project(aliasRequest: #"{"toDeploymentId":"dpl_old","jobStatus":"succeeded","type":"rollback"}"#),
            projectID: "prj_one")
        let context = VercelContextParsers.context(
            project: parsed,
            aliases: try VercelContextParsers.aliases(
                aliases(production: "dpl_old", productionHost: "demo-old-team.vercel.app")),
            comments: nil, items: items)
        XCTAssertEqual(context.production?.deploymentID, "dpl_old")
        XCTAssertEqual(context.production?.commit, older)
        XCTAssertEqual(context.production?.isPinned, true)
        XCTAssertEqual(context.production?.latestCommit, newest)
        // Without the alias list a succeeded alias request still decides.
        let fallback = VercelContextParsers.context(project: parsed, aliases: nil, comments: nil, items: items)
        XCTAssertEqual(fallback.production?.deploymentID, "dpl_old")
        XCTAssertNil(fallback.production?.commit, "no listed host and no detail read: the commit stays unknown")
    }

    func testActionsFollowLiveProduction() throws {
        let parsed = try VercelContextParsers.project(project(), projectID: "prj_one")
        let context = VercelContextParsers.context(
            project: parsed,
            aliases: try VercelContextParsers.aliases(
                aliases(production: "dpl_new", productionHost: "demo-new-team.vercel.app")),
            comments: nil, items: items)
        XCTAssertEqual(
            VercelActionService.Action.allCases.filter {
                VercelActionService.isOffered($0, for: items[0], context: context)
            }, [])
        XCTAssertEqual(
            VercelActionService.Action.allCases.filter {
                VercelActionService.isOffered($0, for: items[1], context: context)
            }, [.rollback])
        XCTAssertEqual(
            VercelActionService.Action.allCases.filter {
                VercelActionService.isOffered($0, for: items[2], context: context)
            }, [.redeploy])
    }

    func testCommentsCountUnresolvedThreadsPerBranchAndRejectAnotherProject() throws {
        let data = Data(
            """
            {"scope":{"teamId":"team_one","projectId":"prj_one"},"threads":[
              {"id":"t1","branch":"feature","resolved":false,"webUrl":"https://vercel.com/team/demo/comments/t1"},
              {"id":"t2","branch":"feature","resolved":false},
              {"id":"t3","branch":"main","resolved":false,"webUrl":"https://vercel.com/team/demo/comments/t3"},
              {"id":"t4","branch":"main","resolved":true}],"pagination":{"nextCursor":null}}
            """.utf8)
        let comments = try VercelContextParsers.comments(data, projectID: "prj_one")
        XCTAssertEqual(comments.byBranch, ["feature": 2, "main": 1])
        XCTAssertNil(comments.threadURLs["feature"], "two threads: no single thread link")
        XCTAssertEqual(comments.threadURLs["main"]?.lastPathComponent, "t3")
        XCTAssertThrowsError(try VercelContextParsers.comments(data, projectID: "prj_two"))
    }

    func testBuildLogKeepsTheLastLinesInOrderAndRedactsTokens() throws {
        let data = Data(
            """
            [{"type":"stderr","text":"Error: Command \\"npm run build\\" exited with 1","level":"error"},
             {"type":"delimiter","text":"Build"},
             {"type":"stderr","text":"  at check (scripts/check.mjs:73:33)\\n\\u001b[31mAssertionError\\u001b[0m"},
             {"type":"stdout",\
            "text":"API_TOKEN=abcd1234secret STRIPE sk_live_abcdefghijklmnop Authorization: Bearer \
            abcdefghijklmnopqrstuvwxyz"},
             {"type":"command","text":"Running \\"npm run build\\""}]
            """.utf8)
        let lines = try VercelContextParsers.buildLog(data)
        XCTAssertEqual(lines.first, #"Running "npm run build""#)
        XCTAssertEqual(lines.last, #"Error: Command "npm run build" exited with 1"#)
        XCTAssertTrue(lines.contains("AssertionError"), "ANSI escapes are stripped")
        let joined = lines.joined(separator: "\n")
        for secret in ["abcd1234secret", "sk_live_abcdefghijklmnop", "abcdefghijklmnopqrstuvwxyz"] {
            XCTAssertFalse(joined.contains(secret), secret)
        }
        XCTAssertFalse(lines.contains("Build"), "delimiters are not output")
    }

    @MainActor
    func testContextReadsOnlyWhenTheDeploymentListChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".vercel"), withIntermediateDirectories: true)
        try Data(#"{"orgId":"team_one","projectId":"prj_one"}"#.utf8).write(
            to: root.appendingPathComponent(".vercel/project.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let list = Data(
            #"{"contextName":"team","deployments":[{"url":"demo-new-team.vercel.app","name":"demo","state":"READY","target":"production","meta":{"githubCommitSha":"\#(newest)","githubCommitRef":"main"}}]}"#
                .utf8)
        let projectData = project()
        let aliasData = aliases(production: "dpl_new", productionHost: "demo-new-team.vercel.app")
        let runner = ContextRunner { call in
            switch call.arguments.first {
            case "list": return CommandResult(stdout: list, stderr: Data(), exitCode: 0)
            case "comments":
                return CommandResult(
                    stdout: Data(#"{"scope":{"projectId":"prj_one"},"threads":[]}"#.utf8), stderr: Data(), exitCode: 0)
            case "api" where call.arguments[1].hasPrefix("/v9/projects/prj_one"):
                return CommandResult(stdout: projectData, stderr: Data(), exitCode: 0)
            case "api" where call.arguments[1].hasPrefix("/v4/aliases"):
                return CommandResult(stdout: aliasData, stderr: Data(), exitCode: 0)
            default: return CommandResult(stdout: Data(), stderr: Data("unexpected".utf8), exitCode: 1)
            }
        }
        let service = ProviderService(runner: runner)
        let first = await service.vercel(root: root, previous: nil, forceContext: false)
        XCTAssertEqual(first.vercel?.production?.commit, newest)
        let firstCalls = await runner.calls.filter { $0.executable == "vercel" }
        // 4 context reads + 7 signal reads (2 error counts, CI, rollout, Agent Runs, alerts, platform status).
        XCTAssertEqual(firstCalls.count, 11)
        XCTAssertTrue(
            firstCalls.filter { $0.arguments.first == "logs" }.allSatisfy {
                $0.arguments.contains("--query") && $0.arguments.contains("dpl_new") && $0.arguments.contains("1h")
                    && !$0.arguments.contains("--follow")
            }, "logs are only counted, for the live deployment's last hour")
        XCTAssertTrue(
            firstCalls.contains {
                $0.arguments == [
                    "api", "/v9/projects/prj_one?teamId=team_one", "--method", "GET", "--raw", "--non-interactive",
                ]
            })
        XCTAssertTrue(
            firstCalls.contains {
                $0.arguments == [
                    "api", "/v4/aliases?projectId=prj_one&limit=100&teamId=team_one", "--method", "GET", "--raw",
                    "--non-interactive",
                ]
            })
        XCTAssertFalse(
            firstCalls.contains {
                ["promote", "rollback", "redeploy", "deploy", "link", "env", "rolling-release"].contains(
                    $0.arguments.first ?? "")
            })

        let second = await service.vercel(root: root, previous: first, forceContext: false)
        XCTAssertEqual(second.vercel, first.vercel)
        let afterSecond = await runner.calls.filter { $0.executable == "vercel" }
        XCTAssertEqual(afterSecond.count, 12, "unchanged list: only `vercel list` runs")

        _ = await service.vercel(root: root, previous: first, forceContext: true)
        let afterForced = await runner.calls.filter { $0.executable == "vercel" }
        XCTAssertEqual(afterForced.count, 23)
    }
}

private actor ContextRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }
    var calls: [Call] = []
    private let response: @Sendable (Call) -> CommandResult
    init(response: @escaping @Sendable (Call) -> CommandResult) { self.response = response }
    func run(
        executable: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        return response(call)
    }
}

/// The parser and builder entry points under the names these tests use.
private enum VercelContextParsers {
    static func project(_ data: Data, projectID: String) throws -> VercelContextParser.Project {
        try VercelContextParser.project(data, projectID: projectID)
    }

    static func aliases(_ data: Data) throws -> [VercelContextParser.Alias] {
        try VercelContextParser.aliases(data)
    }

    static func comments(_ data: Data, projectID: String) throws -> VercelContext.Comments {
        try VercelContextParser.comments(data, projectID: projectID)
    }

    static func context(
        project: VercelContextParser.Project?, aliases: [VercelContextParser.Alias]?,
        comments: VercelContext.Comments? = nil, items: [ProviderItem] = []
    ) -> VercelContext {
        VercelContextBuilder(project: project, aliases: aliases ?? [], comments: comments, items: items, readAt: Date())
            .context()
    }

    static func buildLog(_ data: Data) throws -> [String] {
        try VercelBuildLog.lines(data)
    }
}
