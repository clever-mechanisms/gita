import Foundation
import Testing

@testable import GitaCore

struct CommandRunnerTests {
    @Test func argvIsLiteralAndStdoutStderrAreBothDrained() async throws {
        let runner = CommandRunner()
        let literal = "$(touch /not-a-command); `whoami`\nquotes ' \""
        let result = try await runner.run(
            executable: "/usr/bin/printf", arguments: ["%s", literal], directory: nil, timeout: 3, outputLimit: 4_096)
        #expect(result.text == literal)
        #expect(result.exitCode == 0)
        // This shell is a fixture, never an application command; write beyond pipe capacity to both streams.
        let both = try await runner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                """
                i=0; while [ $i -lt 4000 ]; do printf '01234567890123456789'; printf 'abcdefghijabcdefghij' >&2; \
                i=$((i+1)); done
                """,
            ], directory: nil, timeout: 10, outputLimit: 200_000)
        #expect(both.stdout.count == 80_000)
        #expect(both.stderr.count == 80_000)
    }

    /// An upkeep request's child runs at utility quality of service (scheduler priority 20). A normal request's child
    /// inherits the test runner's own priority (31 on a desktop, but a CI agent may already run at utility or below),
    /// so only the upkeep value is fixed.
    @Test func upkeepRequestsRunAtUtilityPriority() async throws {
        // This shell is a fixture, never an application command.
        var request = CommandRequest(executable: "/bin/sh", arguments: ["-c", "ps -o pri= -p $$"], timeout: 10)
        request.upkeep = true
        let upkeep = try await CommandRunner().run(request)
        #expect(Int(upkeep.text.trimmingCharacters(in: .whitespacesAndNewlines)) == 20)
    }

    @Test func timeoutAndOutputCapEndChildren() async throws {
        let runner = CommandRunner()
        let start = Date()
        do {
            _ = try await runner.run(
                executable: "/bin/sleep", arguments: ["30"], directory: nil, timeout: 0.15, outputLimit: 1_024)
            Issue.record("Expected timeout")
        } catch CommandError.timedOut {} catch { throw error }
        #expect(Date().timeIntervalSince(start) < 3)
        do {
            _ = try await runner.run(
                executable: "/usr/bin/yes", arguments: [], directory: nil, timeout: 5, outputLimit: 1_024)
            Issue.record("Expected bounded-output error")
        } catch CommandError.outputLimitExceeded(let limit) { #expect(limit == 1_024) }
    }

    @Test func cancellationStopsACommandWithoutWaitingForItsDeadline() async throws {
        let start = Date()
        let task = Task {
            try await CommandRunner().run(
                executable: "/bin/sleep", arguments: ["30"], directory: nil, timeout: 30, outputLimit: 1_024)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func missingExecutableAndEmbeddedNULAreRejectedBeforeLaunch() async throws {
        await #expect(throws: CommandError.self) {
            _ = try await CommandRunner().run(
                executable: "gita-not-installed-tool", arguments: [], directory: nil, timeout: 2, outputLimit: 1_024
            )
        }
        await #expect(throws: CommandError.self) {
            _ = try await CommandRunner().run(
                executable: "/usr/bin/printf", arguments: ["%s", "bad\0argument"], directory: nil, timeout: 2,
                outputLimit: 1_024)
        }
    }
}

/// A child starts with no blocked signals, whatever thread started it: cancelling ends it with SIGTERM at once
/// instead of waiting out `ChildProcess.terminationGrace` for SIGKILL.
struct CommandRunnerSignalTests {
    @Test func cancellationEndsTheChildAtOnce() async throws {
        let task = Task.detached {
            try await CommandRunner().run(executable: "/bin/sleep", arguments: ["30"], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
