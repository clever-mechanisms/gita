import Darwin
import Foundation
import Testing

@testable import GitaCore

/// A child's state: running, exited with its zombie kept, then reaped, keeping how it ended either way.
@Suite struct ChildProcessStateTests {
    private func spawn(_ script: String) throws -> ChildProcess {
        try ChildProcess.spawn(
            path: "/bin/sh", request: CommandRequest(executable: "/bin/sh", arguments: ["-c", script]),
            environment: [:])
    }

    private func waitForExit(_ child: ChildProcess) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while try !child.checkExit(), ProcessInfo.processInfo.systemUptime < deadline { usleep(1_000) }
    }

    @Test func anExitIsKeptThroughTheReap() throws {
        let child = try spawn("exit 3")
        #expect(child.state == .running)
        try waitForExit(child)
        #expect(child.state == .exited(.exited(3)))
        child.reap()
        #expect(child.state == .reaped(.exited(3)))
        #expect(child.exitCode == 3)
        // A reaped pid is not ours any more: it is not waited on again.
        #expect(try child.checkExit())
        child.terminate()
        #expect(child.state == .reaped(.exited(3)))
    }

    @Test func aSignalIsTheShellsCode() throws {
        let child = try spawn("kill -9 $$")
        try waitForExit(child)
        #expect(child.termination == .signalled(SIGKILL))
        #expect(child.exitCode == 128 + SIGKILL)
    }

    /// A group that ignores SIGTERM is killed after the grace period, and the reap records that it was.
    @Test func aKilledChildKeepsItsSignal() throws {
        let child = try spawn("trap '' TERM; sleep 30")
        usleep(100_000)
        child.terminate()
        #expect(child.state == .reaped(.signalled(SIGKILL)))
    }

    @Test func waitStatusesDecode() {
        #expect(ChildProcess.termination(0) == .exited(0))
        #expect(ChildProcess.termination(3 << 8) == .exited(3))
        #expect(ChildProcess.termination(SIGTERM) == .signalled(SIGTERM))
    }
}
