import Foundation
import Testing

@testable import GitaCore

/// Forwards to a real runner and keeps every request, so a test can see which time limit each command got.
private actor RequestRecorder: CommandRunning {
    private let runner = CommandRunner()
    private(set) var requests: [CommandRequest] = []

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        try await run(
            CommandRequest(
                executable: executable, arguments: arguments, directory: directory, timeout: timeout,
                outputLimit: outputLimit))
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        return try await runner.run(request)
    }

    func request(running subcommand: String) -> CommandRequest? {
        requests.last { $0.arguments.contains(subcommand) }
    }
}

@Suite struct GitTimeoutTests {
    private static func shell(_ script: String, timeout: TimeInterval, restartsOnOutput: Bool) -> CommandRequest {
        // This shell is a fixture, never an application command.
        var request = CommandRequest(
            executable: "/bin/sh", arguments: ["-c", script], timeout: timeout, outputLimit: 4_096)
        request.timeoutRestartsOnOutput = restartsOnOutput
        return request
    }

    private static func isTimeout(_ error: CommandError?) -> Bool {
        if case .timedOut? = error { return true }
        return false
    }

    @Test func aChildThatKeepsWritingOutlivesTheIdleLimit() async throws {
        let script = "i=0; while [ $i -lt 8 ]; do echo tick >&2; sleep 0.2; i=$((i+1)); done"
        let result = try await CommandRunner().run(Self.shell(script, timeout: 1, restartsOnOutput: true))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").count == 8)
        let fixed = await #expect(throws: CommandError.self) {
            _ = try await CommandRunner().run(Self.shell(script, timeout: 1, restartsOnOutput: false))
        }
        #expect(Self.isTimeout(fixed))
    }

    @Test func aSilentChildStillEndsAtTheIdleLimit() async throws {
        let start = Date()
        let silent = await #expect(throws: CommandError.self) {
            _ = try await CommandRunner().run(Self.shell("echo once; sleep 30", timeout: 0.3, restartsOnOutput: true))
        }
        #expect(Self.isTimeout(silent))
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func literalsAreFixedDeadlinesAndLongCommandsRestartOnOutput() {
        var request = CommandRequest(executable: "git", arguments: [])
        GitTimeout(12).apply(to: &request)
        #expect(request.timeout == 12 && !request.timeoutRestartsOnOutput)
        let literal: GitTimeout = 2.5
        #expect(literal == GitTimeout(2.5))
        GitTimeout.untilIdle.apply(to: &request)
        #expect(request.timeout == GitTimeout.idleLimit && request.timeoutRestartsOnOutput)
    }

    @Test func networkAndHookCommandsHaveNoFixedDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaTimeout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = CommandRunner()
        for arguments in [
            ["init", "--initial-branch=main", "--template="], ["config", "user.name", "T"],
            ["config", "user.email", "t@example.invalid"], ["config", "commit.gpgsign", "false"],
        ] {
            _ = try await setup.run(
                executable: "git", arguments: arguments, directory: root, timeout: 10, outputLimit: 65_536)
        }
        try Data("x\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let recorder = RequestRecorder()
        let service = GitService(root: root, runner: recorder)
        try await service.stage(paths: ["file.txt"])
        try await service.commit(message: "First")
        try await service.fetch(remote: nil)
        // A remote that cannot be reached: the push runs, and fails.
        _ = try await setup.run(
            executable: "git", arguments: ["remote", "add", "origin", root.appendingPathComponent("missing").path],
            directory: root, timeout: 10, outputLimit: 65_536)
        await #expect(throws: GitError.self) { try await service.push() }
        for subcommand in ["commit", "fetch", "push"] {
            let request = try #require(await recorder.request(running: subcommand))
            #expect(request.timeoutRestartsOnOutput, "\(subcommand)")
            #expect(request.timeout == GitTimeout.idleLimit)
        }
        let status = try #require(await recorder.request(running: "add"))
        #expect(!status.timeoutRestartsOnOutput)
        #expect(status.timeout == CommandRequest.defaultTimeout)
    }
}
