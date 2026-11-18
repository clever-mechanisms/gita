import Foundation
import XCTest

@testable import GitaCore

/// How process samples and hook events combine into sessions: which source wins, how hooks find their process, and
/// which processes never become sessions.
final class AgentSessionTests: XCTestCase {
    private let all = Set(AgentTool.allCases)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repo = URL(fileURLWithPath: "/Users/u/projects/app", isDirectory: true)
    private var checkout: AgentCheckout {
        AgentCheckout(
            checkoutRoot: repo, repositoryRoot: repo, gitDirectory: repo.appendingPathComponent(".git"), branch: "main")
    }

    private func sample(
        _ pid: Int32, _ tool: AgentTool = .claudeCode, cwd: String = "/Users/u/projects/app", cpu: Double,
        service: Bool = false, parent: Int32? = nil
    ) -> AgentProcessSample {
        AgentProcessSample(
            tool: tool, pid: pid, parentAgentPID: parent, workingDirectory: cwd, startedAt: start, cpuSeconds: cpu,
            isService: service)
    }

    /// Feeds `seconds` of samples every 2 s at `rate` CPU for each pid; returns the clock after the last sample.
    @discardableResult
    private func run(
        _ book: inout AgentSessionBook, pids: [Int32], rate: Double,
        over window: (from: TimeInterval, seconds: TimeInterval), cpu: inout [Int32: Double],
        extra: [AgentProcessSample] = []
    ) -> TimeInterval {
        let time = window.from
        var clock = time
        while clock <= time + window.seconds {
            if clock > time { for pid in pids { cpu[pid, default: 0] += rate * 2 } }
            book.apply(
                pids.map { sample($0, cpu: cpu[$0, default: 0]) } + extra,
                checkouts: ["/Users/u/projects/app": checkout],
                enabled: all, time: clock, now: start.addingTimeInterval(clock))
            clock += 2
        }
        return clock
    }

    private func state(_ book: AgentSessionBook, _ id: String = "claudeCode-100") -> AgentSession? {
        book.sessions().first { $0.id == id }
    }

    /// Two agents in one checkout (no worktrees) plus a subagent the first one delegated in the same folder: three
    /// sessions, each hook lands on its own process, and the subagent names its parent.
    func testAgentsSharingACheckoutKeepTheirOwnStateAndSubagentsNameTheirParent() {
        var book = AgentSessionBook()
        let samples = [sample(100, cpu: 0), sample(200, cpu: 0), sample(300, cpu: 0, parent: 100)]
        book.apply(samples, checkouts: ["/Users/u/projects/app": checkout], enabled: all, time: 0, now: start)
        XCTAssertEqual(book.sessions().count, 3)
        // The subagent's Stop reaches it through its own pid first, not the parent above it.
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "a", pids: [101, 100]),
            enabled: all, allowHookOnly: false, time: 1, now: start)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "b", pids: [201, 200]),
            enabled: all, allowHookOnly: false, time: 1, now: start)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "c", pids: [301, 300, 150, 100]), enabled: all,
            allowHookOnly: false, time: 2, now: start)
        XCTAssertEqual(state(book, "claudeCode-100")?.state, .working)
        XCTAssertEqual(state(book, "claudeCode-200")?.state, .working)
        XCTAssertEqual(state(book, "claudeCode-300")?.state, .done)
        XCTAssertEqual(state(book, "claudeCode-300")?.isSubagent, true)
        XCTAssertEqual(state(book, "claudeCode-300")?.parentID, "claudeCode-100")
        XCTAssertNil(state(book, "claudeCode-200")?.parentID)
        // A hook that only names the shared folder cannot tell the two agents apart, so it is not guessed.
        XCTAssertEqual(book.match(AgentHookEvent(tool: .claudeCode, event: "Stop", cwd: "/Users/u/projects/app")), nil)
    }

    /// A same-tool process below an agent is that agent's wrapper only in the same folder and terminal with no shell
    /// between; `claude -p` from an agent's shell (same folder) is a delegated run, i.e. a subagent.
    func testNestedAgentIsAWrapperOnlyWithoutShellOrTerminalChange() {
        XCTAssertTrue(AgentProcessClassifier.isWrapper(sameFolder: true, sameTerminal: true, shellBetween: false))
        XCTAssertFalse(AgentProcessClassifier.isWrapper(sameFolder: true, sameTerminal: true, shellBetween: true))
        XCTAssertFalse(AgentProcessClassifier.isWrapper(sameFolder: true, sameTerminal: false, shellBetween: false))
        XCTAssertFalse(AgentProcessClassifier.isWrapper(sameFolder: false, sameTerminal: true, shellBetween: false))
        XCTAssertTrue(AgentProcessClassifier.isShell(path: "/bin/zsh"))
        XCTAssertTrue(AgentProcessClassifier.isShell(path: "/opt/homebrew/bin/fish"))
        XCTAssertFalse(AgentProcessClassifier.isShell(path: "/usr/local/bin/node"))
    }

    func testProcessOnlySessionWorksThenFinishesUnseenThenSeenIsIdle() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        var clock = run(&book, pids: [100], rate: 0.3, over: (from: 0, seconds: 30), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .working)
        XCTAssertEqual(state(book)?.evidence, .process)
        XCTAssertEqual(state(book)?.repositoryRoot, repo)
        XCTAssertEqual(state(book)?.branch, "main")
        clock = run(&book, pids: [100], rate: 0.005, over: (from: clock, seconds: 30), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .done)
        XCTAssertEqual(state(book)?.unseen, true)
        book.markSeen(["claudeCode-100"], now: start.addingTimeInterval(clock))
        XCTAssertEqual(state(book)?.state, .idle)
        XCTAssertEqual(state(book)?.unseen, false)
    }

    func testServicesCountOnlyInsideACheckoutAndDisabledToolsNeverAppear() {
        var book = AgentSessionBook()
        let samples = [
            sample(1, .codex, cwd: "/", cpu: 0, service: true), // ChatGPT helper at /
            sample(2, .codex, cwd: "/Users/u/projects/app", cpu: 0, service: true), // app-server inside a repo
            sample(3, .opencode, cwd: "/Users/u", cpu: 0, service: false), // TUI outside a repo: kept
            sample(4, .claudeCode, cwd: "/Users/u/projects/app", cpu: 0, parent: 9),
        ]
        book.apply(
            samples, checkouts: ["/Users/u/projects/app": checkout], enabled: all.subtracting([.claudeCode]), time: 0,
            now: start)
        XCTAssertEqual(Set(book.sessions().map(\.id)), ["codex-2", "opencode-3"])
        book.apply(samples, checkouts: ["/Users/u/projects/app": checkout], enabled: all, time: 2, now: start)
        XCTAssertEqual(book.sessions().first { $0.id == "claudeCode-4" }?.isSubagent, true)
        XCTAssertNil(book.sessions().first { $0.id == "opencode-3" }?.repositoryRoot)
    }

    func testHooksOwnStateOnceTheyReport() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        var clock = run(&book, pids: [100], rate: 0, over: (from: 0, seconds: 4), cpu: &cpu)
        let prompt = AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "s1", pids: [555, 100])
        XCTAssertEqual(book.handle(prompt, enabled: all, allowHookOnly: false, time: clock, now: start), .applied)
        XCTAssertEqual(state(book)?.state, .working)
        XCTAssertEqual(state(book)?.evidence, .hook)
        // Busy CPU after Stop (title generation, compaction) must not undo an exact "done".
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s1", pids: [556, 100]), enabled: all,
            allowHookOnly: false, time: clock, now: start)
        clock = run(&book, pids: [100], rate: 0.4, over: (from: clock, seconds: 20), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .done)
        XCTAssertEqual(state(book)?.unseen, true)
        // The 60 s "still waiting" reminder after a finished turn changes nothing.
        XCTAssertEqual(
            book.handle(
                AgentHookEvent(tool: .claudeCode, event: "Notification", kind: "idle_prompt", pids: [557, 100]),
                enabled: all, allowHookOnly: false, time: clock, now: start), .ignored)
        XCTAssertEqual(state(book)?.state, .done)
    }

    func testApprovedPermissionPromptResumesWorkingFromCPU() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        var clock = run(&book, pids: [100], rate: 0, over: (from: 0, seconds: 6), cpu: &cpu)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "Notification", kind: "permission_prompt", pids: [100]),
            enabled: all, allowHookOnly: false, time: clock, now: start)
        clock = run(&book, pids: [100], rate: 0.01, over: (from: clock, seconds: 20), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .needsInput, "Waiting for the user is quiet; it stays needs input")
        run(&book, pids: [100], rate: 0.3, over: (from: clock, seconds: 10), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .working)
    }

    func testInterruptedTurnWithoutStopFallsBackToIdle() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        var clock = run(&book, pids: [100], rate: 0, over: (from: 0, seconds: 4), cpu: &cpu)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", pids: [100]), enabled: all,
            allowHookOnly: false, time: clock, now: start)
        clock = run(&book, pids: [100], rate: 0.03, over: (from: clock, seconds: 200), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .working, "Waiting on the model (≈3 %) for minutes is still working")
        clock = run(&book, pids: [100], rate: 0.0, over: (from: clock, seconds: 100), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .working)
        run(&book, pids: [100], rate: 0.0, over: (from: clock, seconds: 40), cpu: &cpu)
        XCTAssertEqual(state(book)?.state, .idle)
    }

    func testSessionEndHidesTheProcessUntilItExitsButClearKeepsIt() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        var clock = run(&book, pids: [100, 200], rate: 0, over: (from: 0, seconds: 2), cpu: &cpu)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "SessionEnd", kind: "clear", pids: [200]), enabled: all,
            allowHookOnly: false, time: clock, now: start)
        XCTAssertEqual(state(book, "claudeCode-200")?.state, .idle)
        XCTAssertEqual(
            book.handle(
                AgentHookEvent(tool: .claudeCode, event: "SessionEnd", kind: "prompt_input_exit", pids: [100]),
                enabled: all, allowHookOnly: false, time: clock, now: start), .removed)
        clock = run(&book, pids: [100, 200], rate: 0, over: (from: clock, seconds: 4), cpu: &cpu)
        XCTAssertNil(state(book), "The exiting process does not come back on the next scan")
        run(&book, pids: [200], rate: 0, over: (from: clock, seconds: 2), cpu: &cpu)
        run(&book, pids: [100, 200], rate: 0, over: (from: clock + 4, seconds: 2), cpu: &cpu)
        XCTAssertNotNil(state(book), "A reused pid after the process exited is a new session")
    }

    func testHooksFindTheirProcessByAncestorThenSessionThenUniqueFolder() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        run(&book, pids: [100, 200], rate: 0, over: (from: 0, seconds: 2), cpu: &cpu)
        // Two sessions in one folder: the folder alone is ambiguous, so the event waits for a rescan.
        let byFolder = AgentHookEvent(
            tool: .claudeCode, event: "Stop", sessionID: "x", cwd: "/Users/u/projects/app", pids: [999])
        XCTAssertEqual(book.handle(byFolder, enabled: all, allowHookOnly: false, time: 4, now: start), .unmatched)
        XCTAssertNil(book.match(byFolder))
        XCTAssertEqual(
            book.match(AgentHookEvent(tool: .claudeCode, event: "Stop", pids: [999, 300, 200])), "claudeCode-200")
        XCTAssertNil(
            book.match(AgentHookEvent(tool: .codex, event: "notify", pids: [200])),
            "A pid of another tool is not a match")
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "s-200", pids: [200]), enabled: all,
            allowHookOnly: false, time: 4, now: start)
        XCTAssertEqual(
            book.match(AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s-200")), "claudeCode-200")
    }

    func testHookOnlySessionIsCreatedThenAbsorbedByItsProcess() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        let event = AgentHookEvent(
            tool: .codex, event: "notify", sessionID: "thread-1", cwd: "/Users/u/projects/other",
            kind: "agent-turn-complete")
        XCTAssertEqual(
            book.handle(event, enabled: all, allowHookOnly: true, time: 0, now: start),
            .created(id: "codex-thread-1", directory: "/Users/u/projects/other"))
        XCTAssertEqual(state(book, "codex-thread-1")?.state, .done)
        XCTAssertNil(state(book, "codex-thread-1")?.pid)
        run(
            &book, pids: [], rate: 0, over: (from: 2, seconds: 2), cpu: &cpu,
            extra: [sample(300, .codex, cwd: "/Users/u/projects/other", cpu: 0)])
        XCTAssertNil(state(book, "codex-thread-1"))
        XCTAssertNotNil(state(book, "codex-300"))
    }

    func testOrderIsUrgencyThenRecencyAndTitlesNeedAnUnambiguousCheckout() {
        var book = AgentSessionBook()
        var cpu: [Int32: Double] = [:]
        run(&book, pids: [100, 200], rate: 0, over: (from: 0, seconds: 2), cpu: &cpu)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "Notification", pids: [200]), enabled: all, allowHookOnly: false,
            time: 4, now: start)
        XCTAssertEqual(book.sessions().map(\.id), ["claudeCode-200", "claudeCode-100"])
        XCTAssertNil(book.sessions(titles: [repo.path: "Fix login"]).first?.title, "Two sessions share the checkout")
    }
}
