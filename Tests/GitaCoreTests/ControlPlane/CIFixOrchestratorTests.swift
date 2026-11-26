import Foundation
import Testing

@testable import GitaCore

@Suite struct CIFixOrchestratorTests {
    private actor GitHubRunner: CommandRunning {
        enum Reply: Sendable {
            case ok(String)
            case failed, cancelled
        }
        private var replies: [Reply]
        private(set) var calls: [CommandRequest] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func run(
            executable: String, arguments: [String], directory: URL?, timeout: TimeInterval,
            outputLimit: Int
        ) async throws -> CommandResult {
            calls.append(
                .init(
                    executable: executable, arguments: arguments, directory: directory,
                    timeout: timeout, outputLimit: outputLimit))
            switch replies.isEmpty ? .failed : replies.removeFirst() {
            case .ok(let log): return CommandResult(stdout: Data(log.utf8), stderr: Data(), exitCode: 0)
            case .failed: return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
            case .cancelled: throw CancellationError()
            }
        }
    }

    @Test func runAndJobSelectionsPreserveLogScope() throws {
        let steps = [WorkflowStep(number: 1, name: "Unit tests", state: .failure)]
        let job = WorkflowJob(id: 4, name: "macOS", state: .failure, steps: steps, stepsTruncated: false)
        let run = WorkflowRunDetail(
            runID: 8, number: 30, attempt: 2, title: "CI", state: .failure,
            jobs: ProviderPage(items: [job]))
        let root = URL(fileURLWithPath: "/tmp/sample")
        let all = try #require(CIFixTarget(run: run, root: root, repository: "org/example", account: .active))
        let selected = try #require(
            CIFixTarget(run: run, job: job, root: root, repository: "org/example", account: .active))
        #expect(all.jobID == nil && all.runNumber == 30 && all.attempt == 2)
        #expect(selected.jobID == 4 && selected.failedStepName == "Unit tests")
    }

    @Test func redactionBeforeTruncation() {
        let long = String(repeating: "α\n", count: 400)
        let log = long + "\u{1b}[31merror: PASSWORD='\u{1b}[0mhide me'\r\n" + String(repeating: "after\n", count: 400)
        let excerpt = CIFixLogSanitizer.excerpt(log)
        #expect(excerpt.truncated)
        #expect(excerpt.text.contains("error: PASSWORD=••••"))
        #expect(!excerpt.text.contains("hide me"))
        #expect(!excerpt.text.contains("\u{1b}"))
        #expect(excerpt.text.components(separatedBy: "\n").count <= 240)
        let huge = CIFixLogSanitizer.excerpt(String(repeating: "中", count: 30_000))
        #expect(huge.truncated && huge.text.utf8.count <= 16_384)
        #expect(!huge.text.contains("\u{fffd}"))
    }

    @Test func accountScopedJobFallbackBuildsEditableContext() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("changed file", "base")
        let sha = try await repo.commit("First")
        try repo.write("changed file", "next")
        let login = try #require(GitHubLogin("engineer"))
        let target = try #require(
            CIFixTarget(
                root: repo.root, repositoryNameWithOwner: "dev/example", runID: 18,
                attempt: 2, workflowName: "Tests", jobID: 23, jobName: "macOS", failedStepName: "Compile",
                account: .named(login)))
        let runner = GitHubRunner([.failed, .ok("Compile error\nTOKEN=very-secret")])
        let context = try await CIFixOrchestrator(runner: runner).load(target: target, gitService: repo.service)
        #expect(context.branch == "main" && context.commitSHA == sha)
        #expect(context.changedFiles == ["changed file"])
        for text in ["main", sha, "Tests", "macOS", "Compile", "changed file", "TOKEN=••••"] {
            #expect(context.prompt.contains(text))
        }
        #expect(!context.prompt.contains("very-secret"))
        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/bin/sh", "/bin/sh"])
        #expect(
            calls.map(\.arguments) == [
                GitHubAccountCommand.arguments(
                    login: login,
                    gh: [
                        "api", "--hostname", "github.com", "--method", "GET",
                        "repos/dev/example/actions/jobs/23/logs",
                    ]),
                GitHubAccountCommand.arguments(
                    login: login,
                    gh: [
                        "run", "view", "18", "--repo", "github.com/dev/example",
                        "--attempt", "2", "--log-failed",
                    ]),
            ])
        #expect(calls.allSatisfy { $0.outputLimit <= 2_097_152 && $0.directory == repo.root })
    }

    @Test func missingCheckoutFailureAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(CIFixTarget(root: root, repositoryNameWithOwner: "../bad", runID: 1) == nil)
        let target = try #require(CIFixTarget(root: root, repositoryNameWithOwner: "org/name", runID: 1, jobID: 2))
        let git = GitService(root: root)
        let offline = try await CIFixOrchestrator(runner: GitHubRunner([.ok("error")])).load(
            target: target, gitService: git)
        #expect(offline.changedFiles.isEmpty && offline.commitSHA == nil)
        await #expect(throws: ControlPlaneError.self) {
            try await CIFixOrchestrator(runner: GitHubRunner([.failed, .failed])).load(target: target, gitService: git)
        }
        let stopped = GitHubRunner([.cancelled])
        await #expect(throws: CancellationError.self) {
            try await CIFixOrchestrator(runner: stopped).load(target: target, gitService: git)
        }
        #expect(await stopped.calls.count == 1)
    }
}
