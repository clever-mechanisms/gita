import Foundation
import Testing

@testable import GitaCore

@Suite("CommitEcosystem AI Commit Message Generator")
struct CommitMessageGeneratorTests {
    @Test func draftStateLifecycleAccessors() {
        let idle = CommitMessageDraftState.idle
        #expect(idle == .idle)
        #expect(idle.errorMessage == nil)

        let generating = CommitMessageDraftState.generating(agent: .claude)
        guard case .generating(.claude) = generating else {
            Issue.record("Expected generating state")
            return
        }

        let message = GeneratedCommitMessage(subject: "Add signing badge", body: "Displays GPG status.", agent: .claude)
        let ready = CommitMessageDraftState.ready(message)
        guard case .ready(let payload) = ready else {
            Issue.record("Expected ready state")
            return
        }
        #expect(payload == message)
        #expect(message.fullMessage == "Add signing badge\n\nDisplays GPG status.")

        let failed = CommitMessageDraftState.failed("CLI timed out")
        #expect(failed.errorMessage == "CLI timed out")
    }

    @Test func nonInteractiveArgumentsUseReadOnlyAndQuietFlags() {
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .claude, prompt: "PROMPT")
                == [
                    "-p", "--model", "sonnet", "--tools", "", "--permission-mode", "plan", "--strict-mcp-config",
                    "PROMPT",
                ]
        )
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .codex, prompt: "PROMPT")
                == [
                    "-c", "check_for_update_on_startup=false", "exec", "--sandbox", "read-only", "--ephemeral",
                    "--skip-git-repo-check", "PROMPT",
                ]
        )
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .cursor, prompt: "PROMPT")
                == ["--disable-auto-update", "--mode", "ask", "-p", "PROMPT"]
        )
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .gemini, prompt: "PROMPT")
                == ["-p", "PROMPT"]
        )
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .opencode, prompt: "PROMPT")
                == ["run", "--agent", "plan", "PROMPT"]
        )
        #expect(
            CommitMessageGenerator.nonInteractiveArguments(for: .grok, prompt: "PROMPT")
                == ["--permission-mode", "plan", "-p", "PROMPT"]
        )
    }

    @Test func buildPromptCapsDiffAndStatSafelyOnUTF8Boundary() {
        let diff = String(repeating: "🚀 line change\n", count: 200)
        let stat = String(repeating: "file.swift | 10 +++++-----\n", count: 40)
        let prompt = CommitMessageGenerator.buildPrompt(
            stagedDiff: diff,
            statSummary: stat,
            maxDiffBytes: 120,
            maxStatBytes: 80
        )
        #expect(prompt.contains("Staged diff summary:"))
        #expect(prompt.contains("[summary truncated]"))
        #expect(prompt.contains("[diff truncated]"))
    }

    @Test func parseResponseStripsFencesAndExtractsSubjectAndBody() throws {
        let fenced = """
            ```
            Commit message: Add submodule status window

            Lists submodules with status pills and explicit sync/update actions.
            ```
            """
        let parsed = try CommitMessageGenerator.parseResponse(fenced, agent: .claude)
        #expect(parsed.subject == "Add submodule status window")
        #expect(parsed.body == "Lists submodules with status pills and explicit sync/update actions.")

        let subjectOnly = try CommitMessageGenerator.parseResponse("\"Fix typo in badge\"\n", agent: .codex)
        #expect(subjectOnly.subject == "Fix typo in badge")
        #expect(subjectOnly.body.isEmpty)
        #expect(subjectOnly.fullMessage == "Fix typo in badge")

        #expect(throws: CommitMessageGeneratorError.emptyOutput(agent: .claude)) {
            _ = try CommitMessageGenerator.parseResponse("   \n``` \n```\n", agent: .claude)
        }
    }

    @Test func generateRunsLocalAgentCLIInIsolatedDirectoryOnStagedDiff() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("app.swift", "let value = 1\n")
        try await fixture.commit("Initial commit")

        let claudeURL = URL(fileURLWithPath: "/usr/local/bin/claude")
        let installed: [ReviewAgent: URL] = [.claude: claudeURL]

        let stubRunner = StubAgentRunner(
            exitCode: 0,
            stdout: "Add greeting constant\n\nIntroduces a greeting string used by tests.\n",
            stderr: ""
        )
        let generator = CommitMessageGenerator(runner: stubRunner, timeout: 15, maxDiffBytes: 4_096)

        await #expect(throws: CommitMessageGeneratorError.noStagedChanges) {
            _ = try await generator.generate(service: fixture.service, installedAgents: installed)
        }

        try fixture.write("app.swift", "let value = 1\nlet greeting = \"hi\"\n")
        try await fixture.git(["add", "app.swift"])

        await #expect(throws: CommitMessageGeneratorError.noAgentInstalled) {
            _ = try await generator.generate(service: fixture.service, installedAgents: [:])
        }

        let generated = try await generator.generate(
            service: fixture.service,
            installedAgents: installed,
            preferredAgent: "claude"
        )
        #expect(generated.subject == "Add greeting constant")
        #expect(generated.body == "Introduces a greeting string used by tests.")
        #expect(generated.agent == .claude)

        let captured = await stubRunner.lastRequest
        #expect(captured?.executable == claudeURL.path)
        #expect(captured?.directory != fixture.root)
        #expect(captured?.directory?.lastPathComponent.hasPrefix("GitaCommitAssist-") == true)
        #expect(
            captured?.arguments.prefix(8)
                == ["-p", "--model", "sonnet", "--tools", "", "--permission-mode", "plan", "--strict-mcp-config"])
        #expect(captured?.arguments.last?.contains("let greeting") == true)
    }

    @Test func generateReportsAgentFailure() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("a.txt", "hello\n")
        try await fixture.git(["add", "a.txt"])

        let stubRunner = StubAgentRunner(exitCode: 1, stdout: "", stderr: "rate limited")
        let generator = CommitMessageGenerator(runner: stubRunner)
        let installed: [ReviewAgent: URL] = [.codex: URL(fileURLWithPath: "/usr/local/bin/codex")]

        await #expect(throws: CommitMessageGeneratorError.agentFailed(agent: .codex, detail: "rate limited")) {
            _ = try await generator.generate(service: fixture.service, installedAgents: installed)
        }
    }
}

private actor StubAgentRunner: CommandRunning {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    private(set) var lastRequest: CommandRequest?

    init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    func run(
        executable: String,
        arguments: [String],
        directory: URL?,
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult {
        lastRequest = CommandRequest(
            executable: executable,
            arguments: arguments,
            directory: directory,
            timeout: timeout,
            outputLimit: outputLimit
        )
        return CommandResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: exitCode)
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        lastRequest = request
        return CommandResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: exitCode)
    }
}
