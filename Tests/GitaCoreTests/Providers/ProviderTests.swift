import Foundation
import XCTest

@testable import GitaCore

final class ProviderTests: XCTestCase {
    func testRemoteIdentityCannotInjectArgumentsOrUseForeignHosts() {
        XCTAssertEqual(
            githubRepository("git@github.com:clever-mechanisms/gita.git"),
            "clever-mechanisms/gita")
        XCTAssertEqual(githubRepository("https://github.com/org/repo.git"), "org/repo")
        XCTAssertEqual(githubRepository("ssh://git@github.com/org/repo.git"), "org/repo")
        // Credentials in the URL are dropped, never used as the account hint.
        XCTAssertEqual(githubRepository("https://user:password@github.com/org/repo"), "org/repo")
        XCTAssertNil(gitHubRemote("https://user:password@github.com/org/repo")?.loginHint)
        for remote in [
            "https://github.com.evil.test/org/repo", "git@gitlab.com:org/repo.git", "https://github.com/org/repo/extra",
            "--help", "git@github.com:org/repo\n--json",
            "file:///org/repo", "https://github.com/../repo",
        ] {
            XCTAssertNil(githubRepository(remote), remote)
        }
    }

    func testWorkflowConclusionOverridesCompletedStatusAndCarriesCommit() throws {
        let rows = try ProviderParsers.githubRuns(
            json(
                """
                [{"databaseId":9,"workflowName":"CI","displayTitle":"Build","headSha":"abc","headBranch":"feature/a",\
                "status":"completed","conclusion":"timed_out","url":"https://github.com/org/repo/actions/runs/9",\
                "updatedAt":"2026-11-06T20:00:00Z"},
                {"databaseId":10,"workflowName":"Test","status":"in_progress","conclusion":"",\
                "url":"javascript:alert(1)"}]
                """))
        XCTAssertEqual(rows[0].state, .failure)
        XCTAssertEqual(rows[0].commit, "abc")
        XCTAssertEqual(rows[0].branch, "feature/a")
        XCTAssertNotNil(rows[0].date)
        XCTAssertEqual(rows[1].state, .running)
        XCTAssertNil(rows[1].url)
    }

    func testVercelPreviewAndProductionPreserveSHAWithoutInventedMetadata() throws {
        let items = try ProviderParsers.vercelDeployments(
            json(
                """
                {"deployments":[
                {"url":"demo-abc.vercel.app","name":"demo","state":"READY","target":"production",\
                "createdAt":1793999680521,"meta":{"githubCommitSha":"abc","githubCommitRef":"main"}},
                {"url":"demo-def.vercel.app","name":"demo","state":"BUILDING","target":null,"meta":{}},
                {"url":"https://user:secret@evil.test","state":"READY"}]}
                """))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].detail, "Production · Ready")
        XCTAssertEqual(items[0].url?.absoluteString, "https://demo-abc.vercel.app")
        XCTAssertEqual(items[0].commit, "abc")
        XCTAssertEqual(items[1].detail, "Preview · Running")
        XCTAssertNil(items[1].commit)
        XCTAssertEqual(items[1].state, .running)
    }

    func testRuntimeStateBeatsStaleAgentHookAndRemotePathCannotImpersonateLocal() throws {
        let path = OrcaAgentParser.normalizedPath("/tmp/gita-test")
        let payload = json(
            """
            {"ok":true,"result":{"worktrees":[
            {"path":"/tmp/gita-test","hostId":"local","branch":"refs/heads/main","terminalVerdict":"live","agents":[
            {"paneKey":"one","agentType":"codex","state":"working","hasLivePty":true,"programStatus":{"state":"done"},\
            "prompt":"DO NOT DISPLAY","toolInput":"DO NOT DISPLAY"},
            {"paneKey":"two","agentType":"antigravity","state":"working","hasLivePty":false,\
            "programStatus":{"state":"working"}},
            {"paneKey":"three","agentType":"codex","hasLivePty":true,"programStatus":{"state":"blocked"},\
            "subagentObservation":"stale","subagents":[{"id":"stale","state":"working"}]},
            {"paneKey":"four","agentType":"codex","hasLivePty":true,"programStatus":{"state":"working"},\
            "subagentObservation":"live","subagents":[{"id":"live","state":"working","description":"Parser"}]}]},
            {"path":"/tmp/gita-test","hostId":"ssh:host","terminalVerdict":"live","agents":[{"paneKey":"remote",\
            "hasLivePty":true,"state":"working"}]},
            {"path":"/tmp/gita-test","terminalVerdict":"live","agents":[{"paneKey":"hostless",\
            "hasLivePty":true,"state":"working"}]},
            {"path":"/tmp/unrelated","hostId":"local","terminalVerdict":"live","agents":[{"paneKey":"other",\
            "hasLivePty":true,"state":"working"}]}],"truncated":true,"hostScope":{"omittedHostIds":["paired"]}}}
            """)
        let parsed = try OrcaAgentParser.page(
            payload,
            worktrees: [
                GitWorktree(path: path, branch: "main", head: "abcd", isBare: false, isLocked: false, isPrunable: false)
            ])
        XCTAssertEqual(parsed.items.count, 5)
        XCTAssertEqual(parsed.items[0].detail, "Idle")
        XCTAssertEqual(parsed.items[0].state, .neutral)
        XCTAssertEqual(parsed.items[1].detail, "Unverified")
        XCTAssertEqual(parsed.items[1].agent?.agentName, "Antigravity")
        XCTAssertEqual(parsed.items[1].reportedAgentTool, .antigravity)
        XCTAssertEqual(parsed.items[2].state, .pending)
        XCTAssertEqual(parsed.items.filter { $0.state == .running }.count, 2)
        XCTAssertTrue(parsed.truncated)
        XCTAssertTrue(parsed.remoteHostsOmitted)
        let sessions = parsed.items.filter { $0.agent?.role == .session }
        XCTAssertEqual(sessions.count, 4)
        XCTAssertTrue(sessions.allSatisfy { $0.worktreePath == path && $0.commit == "abcd" })
        // A delegated subagent has no checkout of its own; its parent's workspace is provenance only.
        let subagents = parsed.items.filter { $0.agent?.role == .subagent }
        XCTAssertEqual(subagents.count, 1)
        XCTAssertTrue(
            subagents.allSatisfy {
                $0.worktreePath == nil && $0.commit == nil
            })
        XCTAssertFalse(
            parsed.items.contains { $0.title.contains("DO NOT DISPLAY") || $0.detail.contains("DO NOT DISPLAY") })
    }

    func testMalformedProviderResponsesFailInsteadOfReturningFakeEmptySuccess() {
        XCTAssertThrowsError(try ProviderParsers.githubRuns(json("{}")))
        XCTAssertThrowsError(try ProviderParsers.vercelDeployments(json("[]")))
        XCTAssertThrowsError(try OrcaAgentParser.page(json("{\"ok\":false}"), worktrees: []))
    }

    /// "Show in Orca": the agent's tab is the one titled with its task, else the one that printed last; other hosts,
    /// other worktrees and disconnected terminals never match.
    func testOrcaTerminalHandlePicksTheAgentsTab() throws {
        func terminal(
            _ handle: String, path: String = "/tmp/gp-orca", title: String? = nil, last: Int? = nil,
            host: String? = "local", connected: Bool = true
        ) -> String {
            "{\"handle\":\"\(handle)\",\"worktreePath\":\"\(path)\",\"title\":\(title.map { "\"\($0)\"" } ?? "null"),\"lastOutputAt\":\(last.map(String.init) ?? "null"),\"executionHostId\":\(host.map { "\"\($0)\"" } ?? "null"),\"connected\":\(connected)}"
        }
        func list(_ rows: [String]) -> Data {
            json("{\"ok\":true,\"result\":{\"terminals\":[\(rows.joined(separator: ","))]}}")
        }
        let rows = [
            terminal("term_shell"), terminal("term_agent", title: "Translate the app", last: 10),
            terminal("term_busy", last: 99),
            terminal("term_remote", title: "Translate the app", last: 500, host: "ssh-box"),
            terminal("term_hostless", title: "Translate the app", last: 600, host: nil),
            terminal("term_other", path: "/tmp/elsewhere", last: 900),
        ]
        XCTAssertEqual(
            try OrcaTerminalParser.handle(list(rows), checkout: "/tmp/gp-orca", title: "Translate the app"),
            "term_agent")
        XCTAssertEqual(
            try OrcaTerminalParser.handle(list(rows), checkout: "/tmp/gp-orca", title: nil), "term_busy")
        XCTAssertEqual(
            try OrcaTerminalParser.handle(list([terminal("term_only")]), checkout: "/tmp/gp-orca", title: "x"),
            "term_only")
        XCTAssertNil(
            try OrcaTerminalParser.handle(
                list([terminal("term_a"), terminal("term_b")]), checkout: "/tmp/gp-orca", title: nil))
        XCTAssertNil(
            try OrcaTerminalParser.handle(
                list([terminal("term_off", connected: false)]), checkout: "/tmp/gp-orca", title: nil))
        XCTAssertThrowsError(
            try OrcaTerminalParser.handle(json("{\"ok\":false}"), checkout: "/tmp/gp-orca", title: nil))
    }

    @MainActor
    func testGithubPartialFailurePreservesSuccessfulRunsAndNeverLeaksStderr() async {
        let runner = RecordingRunner { call in
            if call.arguments[0] == "run" {
                return CommandResult(
                    stdout: Data("[{\"databaseId\":1,\"workflowName\":\"CI\",\"status\":\"in_progress\"}]".utf8),
                    stderr: Data(), exitCode: 0)
            }
            return CommandResult(
                stdout: Data(), stderr: Data("401 Unauthorized token=this-must-never-appear".utf8), exitCode: 1)
        }
        let listing = await ProviderService(runner: runner).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: "git@github.com:org/repo.git",
            remote: gitHubRemote("git@github.com:org/repo.git"), choice: nil)
        let report = listing.report
        XCTAssertEqual(report.status, .partial)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertFalse(report.diagnostic?.contains("this-must-never-appear") ?? true)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(
            calls.allSatisfy { $0.executable == "gh" && $0.timeout == 20 && $0.outputLimit == 2 * 1024 * 1024 })
        XCTAssertTrue(
            calls.contains {
                $0.arguments.contains("--repo") && $0.arguments.contains("github.com/org/repo")
                    && $0.arguments.contains("--limit")
            })
        XCTAssertTrue(
            calls.contains {
                $0.arguments.contains("graphql") && $0.arguments.contains("owner=org")
                    && $0.arguments.contains("name=repo")
            })
    }

    @MainActor
    func testMissingRemoteDoesNotLaunchCLI() async {
        let runner = RecordingRunner { _ in
            XCTFail("No command expected")
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let listing = await ProviderService(runner: runner).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: nil, remote: nil, choice: nil)
        let report = listing.report
        XCTAssertEqual(report.status, .noRemote)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testMissingExecutableReportsNotInstalledFromTypedRunnerError() async {
        let runner = RecordingRunner { _ in throw CommandError.executableNotFound("gh") }
        let listing = await ProviderService(runner: runner).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: "https://github.com/org/repo.git",
            remote: gitHubRemote("https://github.com/org/repo.git"), choice: nil)
        let report = listing.report
        XCTAssertEqual(report.status, .notInstalled)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertTrue(report.diagnostic?.contains("Install the GitHub CLI") ?? false)
    }

    @MainActor
    func testOrcaErrorEnvelopeIsOfflineAndDoesNotStartRuntime() async {
        let runner = RecordingRunner { call in
            if call.executable == "git" {
                return CommandResult(
                    stdout: Data("worktree /tmp/repo\0HEAD abcd\0\0".utf8), stderr: Data(), exitCode: 0)
            }
            return CommandResult(
                stdout: Data("{\"ok\":false,\"error\":{\"message\":\"Orca is not running\"}}".utf8), stderr: Data(),
                exitCode: 0)
        }
        let report = await ProviderService(runner: runner).orca(root: URL(fileURLWithPath: "/tmp/repo"))
        XCTAssertEqual(report.status, .offline)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.first { $0.executable == "orca" }?.arguments,
            ["worktree", "ps", "--json", "--agent-wait", "--limit", "100"])
        XCTAssertFalse(calls.contains { $0.arguments.contains("open") })
    }

    @MainActor
    func testOrcaReadsEveryKnownCheckoutWithOneOrcaCallAndNoGit() async {
        let runner = RecordingRunner { _ in
            CommandResult(
                stdout: Data(
                    """
                    {"ok":true,"result":{"worktrees":[\
                    {"path":"/tmp/one","hostId":"local","agents":[{"paneKey":"a","agentType":"codex"}]},\
                    {"path":"/tmp/two","hostId":"local","agents":[{"paneKey":"b","agentType":"claude"}]},\
                    {"path":"/tmp/three","hostId":"local","agents":[{"paneKey":"c","agentType":"claude"}]}]}}
                    """.utf8), stderr: Data(), exitCode: 0)
        }
        let checkouts = [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]
        let report = await ProviderService(runner: runner).orca(checkouts: checkouts)
        XCTAssertEqual(Set(report.items.compactMap(\.worktreePath)), ["/tmp/one", "/tmp/two"])
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable), ["orca"])
        let none = await ProviderService(runner: runner).orca(checkouts: [])
        XCTAssertEqual(none.status, .unavailable)
    }

    @MainActor
    func testVercelUsesExistingWorktreeLinkWithoutLinkOrDeployCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let main = root.appendingPathComponent("main")
        let work = root.appendingPathComponent("feature")
        // Sibling fallback needs a proven absence of this checkout's own link; a missing directory fails closed.
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: main.appendingPathComponent(".vercel"), withIntermediateDirectories: true)
        try Data(#"{"orgId":"team_one","projectId":"prj_one"}"#.utf8).write(
            to: main.appendingPathComponent(".vercel/project.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingRunner { call in
            if call.executable == "git" {
                return CommandResult(
                    stdout: Data("worktree \(main.path)\0HEAD abcd\0\0worktree \(work.path)\0HEAD efgh\0\0".utf8),
                    stderr: Data(), exitCode: 0)
            }
            return CommandResult(stdout: Data("{\"deployments\":[]}".utf8), stderr: Data(), exitCode: 0)
        }
        let report = await ProviderService(runner: runner).vercelProvider.list(root: work).report
        XCTAssertEqual(report.status, .connected)
        // The link is resolved again after the read so a project change cannot relabel its deployments.
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.executable), ["git", "vercel", "git"])
        XCTAssertTrue(
            calls.filter { $0.executable == "git" }.allSatisfy {
                $0.arguments == ["worktree", "list", "--porcelain", "-z"]
            })
        let call = calls.first { $0.executable == "vercel" }
        XCTAssertEqual(call?.arguments, ["list", "--json", "--limit", "30"])
        XCTAssertEqual(call?.directory?.resolvingSymlinksInPath().path, main.resolvingSymlinksInPath().path)
    }

    private func json(_ string: String) -> Data { Data(string.utf8) }
}

private actor RecordingRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let directory: URL?
        let timeout: TimeInterval
        let outputLimit: Int
    }
    var calls: [Call] = []
    private let response: @Sendable (Call) throws -> CommandResult
    init(response: @escaping @Sendable (Call) throws -> CommandResult) { self.response = response }
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        let call = Call(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
        calls.append(call)
        return try response(call)
    }
}

/// The `owner/name` a remote URL names on github.com, or nil.
private func githubRepository(_ remote: String) -> String? {
    gitHubRemote(remote)?.repository.nameWithOwner
}
