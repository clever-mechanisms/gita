import Foundation
import XCTest

@testable import GitaCore

/// States Orca reports for the agents in its terminals: where they apply, what a finished turn becomes, and how they
/// give way to hooks and, once stale, to CPU inference.
final class AgentReportedStateTests: XCTestCase {
    private let all = Set(AgentTool.allCases)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repo = URL(fileURLWithPath: "/Users/u/projects/app", isDirectory: true)
    private var checkout: AgentCheckout {
        AgentCheckout(
            checkoutRoot: repo, repositoryRoot: repo, gitDirectory: repo.appendingPathComponent(".git"), branch: "main")
    }

    private func book(_ pids: [Int32], tool: AgentTool = .claudeCode) -> AgentSessionBook {
        var book = AgentSessionBook()
        let samples = pids.map {
            AgentProcessSample(
                tool: tool, pid: $0, parentAgentPID: nil, workingDirectory: repo.path, startedAt: start, cpuSeconds: 0,
                isService: false)
        }
        book.apply(samples, checkouts: [repo.path: checkout], enabled: all, time: 0, now: start)
        return book
    }
    private func report(_ state: AgentState, tool: AgentTool = .claudeCode) -> AgentStateReport {
        AgentStateReport(tool: tool, checkout: repo.path, state: state)
    }

    func testAReportedTurnRunsThenFinishesUnseen() throws {
        var book = book([100])
        XCTAssertTrue(book.applyReported([report(.working)], time: 1, now: start))
        XCTAssertEqual(book.sessions().first?.state, .working)
        XCTAssertEqual(book.sessions().first?.evidence, .orca)
        book.applyReported([report(.needsInput)], time: 2, now: start)
        XCTAssertEqual(book.sessions().first?.state, .needsInput)
        book.applyReported([report(.working)], time: 3, now: start)
        book.applyReported([report(.idle)], time: 4, now: start)
        let finished = try XCTUnwrap(book.sessions().first)
        XCTAssertEqual(finished.state, .done)
        XCTAssertTrue(finished.unseen)
        // Idle again does not hide the unseen result; seeing it does.
        XCTAssertFalse(book.applyReported([report(.idle)], time: 5, now: start))
        book.markSeen([finished.id], now: start)
        book.applyReported([report(.idle)], time: 6, now: start)
        XCTAssertEqual(book.sessions().first?.state, .idle)
        book.applyReported([report(.done)], time: 7, now: start)
        XCTAssertEqual(book.sessions().first?.state, .done)
    }

    func testReportsOwnTheStateUntilTheyStop() {
        var book = book([100])
        book.applyReported([report(.working)], time: 0, now: start)
        // CPU at rest would settle a working session; a fresh report keeps it working.
        for time in stride(from: 2.0, through: 40, by: 2) {
            book.apply(
                [
                    AgentProcessSample(
                        tool: .claudeCode, pid: 100, parentAgentPID: nil, workingDirectory: repo.path,
                        startedAt: start, cpuSeconds: 0, isService: false)
                ], checkouts: [repo.path: checkout], enabled: all, time: time, now: start)
        }
        XCTAssertEqual(book.sessions().first?.state, .working)
        XCTAssertLessThan(40, AgentSessionBook.reportLifetime)
    }

    func testAmbiguousOrHookedSessionsKeepTheirOwnState() {
        var two = book([100, 200])
        XCTAssertFalse(two.applyReported([report(.working)], time: 1, now: start))
        var one = book([100])
        XCTAssertFalse(one.applyReported([report(.working), report(.needsInput)], time: 1, now: start))
        XCTAssertFalse(one.applyReported([report(.working, tool: .codex)], time: 1, now: start))
        _ = one.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", pids: [100]), enabled: all,
            allowHookOnly: false, time: 1, now: start)
        XCTAssertFalse(one.applyReported([report(.needsInput)], time: 2, now: start))
        XCTAssertEqual(one.sessions().first?.evidence, .hook)
    }

    func testOrcaItemsNameTheirToolAndState() {
        func item(_ name: String, _ detail: String, role: AgentMetadata.Role = .session) -> ProviderItem {
            ProviderItem(
                id: name + detail, provider: .orca, category: "", title: name, state: .neutral, detail: detail,
                kind: .agent, agent: AgentMetadata(role: role, agentName: name))
        }
        XCTAssertEqual(item("Claude Code", "Working").reportedAgentTool, .claudeCode)
        XCTAssertEqual(item("Codex", "Needs attention").reportedAgentState, .needsInput)
        XCTAssertEqual(item("Cursor", "Idle").reportedAgentTool, .cursorAgent)
        XCTAssertEqual(item("Gemini", "Failed").reportedAgentTool, .gemini)
        XCTAssertEqual(item("Gemini", "Cancelled").reportedAgentState, .idle)
        XCTAssertEqual(item("Antigravity", "Done").reportedAgentTool, .antigravity)
        XCTAssertEqual(item("Claude Code", "Working").reportedAgentState, .working)
        XCTAssertNil(item("Claude Code", "Unverified").reportedAgentState)
        XCTAssertNil(item("Claude Code", "Working", role: .subagent).reportedAgentState)
        XCTAssertNil(item("Some Agent", "Working").reportedAgentTool)
        XCTAssertNil(
            ProviderItem(id: "x", provider: .github, category: "", title: "", state: .success, detail: "Working")
                .reportedAgentState)
    }
}
