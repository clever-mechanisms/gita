import Darwin
import Foundation
import XCTest

@testable import GitaCore

/// Process classification, live libproc sampling and the CPU hysteresis that turns samples into working/idle.
final class AgentDetectionTests: XCTestCase {
    // MARK: Classification

    func testAgentBinariesAreRecognisedByPathEvenWhenNamedByVersion() {
        // Claude Code's native binary is named after its version; `ps` shows "claude" only because of argv[0].
        XCTAssertEqual(
            AgentProcessClassifier.classify(path: "/Users/u/.local/share/claude/versions/2.1.319"),
            AgentProcessIdentity(tool: .claudeCode, isService: false))
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/Users/u/.codex/packages/standalone/releases/0.166.0-aarch64-apple-darwin/bin/codex"),
            AgentProcessIdentity(tool: .codex, isService: false))
        XCTAssertEqual(AgentProcessClassifier.classify(path: "/Users/u/.opencode/bin/opencode")?.tool, .opencode)
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/Users/u/.local/share/cursor-agent/versions/2026.11.05-86047df/node",
                arguments: ["node", "index.js"])?.tool, .cursorAgent)
        XCTAssertNil(AgentProcessClassifier.classify(path: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertNil(AgentProcessClassifier.classify(path: "/bin/zsh"))
    }

    func testDesktopAppHelpersAndDaemonsAreServicesThatNeedACheckout() {
        let chatGPT = AgentProcessClassifier.classify(
            path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        XCTAssertEqual(chatGPT, AgentProcessIdentity(tool: .codex, isService: true))
        let daemon = AgentProcessClassifier.classify(
            path: "/Users/u/.codex/packages/app-server-daemon/releases/0.167.0-aarch64-apple-darwin/bin/codex")
        XCTAssertEqual(daemon?.isService, true)
        XCTAssertEqual(
            AgentProcessClassifier.classify(path: "/opt/homebrew/bin/codex", arguments: ["codex", "app-server"])?
                .isService, true)
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/Users/u/.opencode/bin/opencode", arguments: ["opencode", "serve", "--service"])?.isService, true
        )
        XCTAssertNil(
            AgentProcessClassifier.classify(
                path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host"))
        XCTAssertNil(
            AgentProcessClassifier.classify(path: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl")
        )
    }

    func testInterpreterProcessesAreClassifiedOnlyByTheirScript() {
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/opt/homebrew/Cellar/node/26.1/bin/node", arguments: ["node", "/opt/homebrew/bin/gemini"])?.tool,
            .gemini)
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/usr/local/bin/node",
                arguments: ["node", "--no-warnings", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"])?
                .tool, .claudeCode)
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/opt/homebrew/bin/python3.12", arguments: ["python3", "-m", "aider", "--model", "x"])?.tool,
            .aider)
        XCTAssertEqual(
            AgentProcessClassifier.classify(
                path: "/Users/u/.local/pipx/venvs/aider-chat/bin/python",
                arguments: ["python", "/Users/u/.local/bin/aider"])?.tool, .aider)
        // A script that merely mentions an agent in a later argument is not that agent.
        XCTAssertNil(
            AgentProcessClassifier.classify(
                path: "/usr/local/bin/node", arguments: ["node", "server.js", "--name", "claude"]))
        XCTAssertNil(
            AgentProcessClassifier.classify(path: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"]))
        XCTAssertTrue(AgentProcessClassifier.isInterpreter(path: "/opt/homebrew/bin/python3.12"))
        XCTAssertFalse(AgentProcessClassifier.isInterpreter(path: "/Users/u/.local/share/claude/versions/2.1.319"))
    }

    // MARK: Live libproc scan

    /// A tiny compiled program named `claude` stands in for an agent (copies of system binaries are killed by macOS):
    /// found by path, cwd read through libproc, no terminal (so it is a service), and CPU burnt only by its child
    /// (`/usr/bin/yes`) still counts toward the session.
    func testLiveScanFindsAgentFolderAndCountsChildCPU() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaAgentScan-" + UUID().uuidString, isDirectory: true)
        let folder = container.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let source = container.appendingPathComponent("agent.c")
        try Data(
            """
            #include <fcntl.h>
            #include <unistd.h>
            #include <sys/wait.h>
            int main(void) {
                pid_t child = fork();
                if (child == 0) { int fd = open("/dev/null", O_WRONLY); dup2(fd, 1); execl("/usr/bin/yes", "yes", \
            (char *)0); _exit(1); }
                int status; waitpid(child, &status, 0); return 0;
            }
            """.utf8
        ).write(to: source)
        let fakeAgent = container.appendingPathComponent("claude").path
        let compiled = try await CommandRunner().run(
            executable: "cc", arguments: ["-O0", "-o", fakeAgent, source.path], timeout: 60)
        guard compiled.exitCode == 0 else { throw XCTSkip("No C compiler to build the stand-in agent") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: fakeAgent)
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        defer {
            for child in childPIDs(of: pid) { kill(child, SIGKILL) }
            kill(pid, SIGKILL)
        }

        let scanner = AgentProcessScanner()
        try await Task.sleep(for: .milliseconds(300))
        let first = await scanner.scan()
        let sample = try XCTUnwrap(first.first { $0.pid == pid })
        XCTAssertEqual(sample.tool, .claudeCode)
        XCTAssertEqual(
            URL(fileURLWithPath: sample.workingDirectory).standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertTrue(sample.isService)
        XCTAssertEqual(sample.cpuSeconds, 0, "The first sight of a process is a baseline, not work")
        try await Task.sleep(for: .milliseconds(1_200))
        let later = await scanner.scan()
        let second = try XCTUnwrap(later.first { $0.pid == pid })
        XCTAssertGreaterThan(second.cpuSeconds, 0.5, "The busy child's CPU belongs to the agent session")
        XCTAssertFalse(childPIDs(of: pid).isEmpty)
    }

    private func childPIDs(of parent: Int32) -> [Int32] {
        AgentProcessTable.allPIDs().filter { AgentProcessTable.entry($0)?.parent == parent }
    }

    // MARK: Hysteresis

    private func feed(
        _ tracker: inout AgentActivityTracker, rate: Double, from start: TimeInterval, to end: TimeInterval,
        step: TimeInterval = 2, cpu: inout Double
    ) -> [AgentActivityTracker.Transition] {
        var transitions: [AgentActivityTracker.Transition] = []
        var time = start
        while time <= end {
            if time > start { cpu += rate * step }
            if let transition = tracker.add(time: time, cpu: cpu) { transitions.append(transition) }
            time += step
        }
        return transitions
    }

    func testIdleTerminalRedrawsNeverReadAsWorking() {
        var tracker = AgentActivityTracker()
        var cpu = 0.0
        // An idle Claude Code TUI: 0.2–2.6 % with occasional spikes inside one 2 s interval.
        var time: TimeInterval = 0
        for (index, rate) in [0.01, 0.026, 0.004, 0.02, 0.06, 0.01, 0.002, 0.02, 0.015, 0.01].enumerated() {
            if index > 0 { cpu += rate * 2 }
            XCTAssertNil(tracker.add(time: time, cpu: cpu))
            time += 2
        }
        XCTAssertFalse(tracker.isWorking)
        XCTAssertTrue(tracker.hasDecided)
    }

    func testSustainedWorkStartsThenFinishesAfterQuietPeriod() {
        var tracker = AgentActivityTracker()
        var cpu = 0.0
        XCTAssertEqual(feed(&tracker, rate: 0.12, from: 0, to: 30, cpu: &cpu), [.started])
        // Waiting on the model (≈3 %) keeps it working: below the start level, above the sustain level.
        XCTAssertEqual(feed(&tracker, rate: 0.03, from: 32, to: 60, cpu: &cpu), [])
        XCTAssertTrue(tracker.isWorking)
        let quiet = feed(&tracker, rate: 0.005, from: 62, to: 100, cpu: &cpu)
        XCTAssertEqual(quiet, [.finished])
        XCTAssertFalse(tracker.isWorking)
    }

    func testShortBurstSettlesWithoutCountingAsFinishedTurn() {
        var tracker = AgentActivityTracker()
        var cpu = 0.0
        _ = feed(&tracker, rate: 0.0, from: 0, to: 8, cpu: &cpu)
        // Six seconds of activity (e.g. a resize redraw storm) then nothing.
        XCTAssertEqual(feed(&tracker, rate: 0.25, from: 10, to: 14, cpu: &cpu), [.started])
        XCTAssertEqual(feed(&tracker, rate: 0.0, from: 16, to: 60, cpu: &cpu), [.settled])
    }

    func testHiddenThirtySecondCadenceStillDecides() {
        var tracker = AgentActivityTracker()
        var cpu = 0.0
        XCTAssertEqual(feed(&tracker, rate: 0.2, from: 0, to: 90, step: 30, cpu: &cpu), [.started])
        XCTAssertEqual(feed(&tracker, rate: 0.0, from: 120, to: 150, step: 30, cpu: &cpu), [.finished])
    }

    func testFirstDecisionNeedsOnlyTheBootstrapSpan() {
        var tracker = AgentActivityTracker()
        var cpu = 0.0
        XCTAssertNil(tracker.add(time: 0, cpu: cpu))
        cpu += 0.2 * 1.5
        XCTAssertEqual(
            tracker.add(time: 1.5, cpu: cpu), .started,
            "A busy agent shows as working on the second sample after launch")
    }

    func testCPUGoingBackwardsIsClampedNotNegative() {
        var tracker = AgentActivityTracker()
        tracker.add(time: 0, cpu: 10)
        // e.g. a pid reused; the scanner normally prevents this. A negative rate would read as idle-to-busy noise.
        XCTAssertNil(tracker.add(time: 2, cpu: 4))
    }
}
