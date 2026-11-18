import Foundation
import Testing

@testable import GitaCore

struct AgentTallyTests {
    private func session(_ id: String, _ tool: AgentTool, _ state: AgentState, subagent: Bool = false) -> AgentSession {
        AgentSession(
            id: id, tool: tool, pid: nil, workingDirectory: URL(fileURLWithPath: "/tmp/repo"), state: state,
            stateSince: Date(), evidence: .hook, isSubagent: subagent)
    }

    @Test func oneTallyPerToolInToolOrder() {
        let tallies = AgentTally.byTool([
            session("x1", .codex, .idle), session("c1", .claudeCode, .working), session("c2", .claudeCode, .done),
            session("c3", .claudeCode, .working, subagent: true),
        ])
        #expect(
            tallies == [
                AgentTally(tool: .claudeCode, state: .working, count: 2),
                AgentTally(tool: .codex, state: .idle, count: 1),
            ])
    }
    @Test func anyWorkingSessionMakesTheToolWorking() {
        // A waiting subagent does not stop the mark turning while another agent of that tool works.
        let tallies = AgentTally.byTool([
            session("c1", .claudeCode, .working), session("c2", .claudeCode, .needsInput, subagent: true),
        ])
        #expect(tallies == [AgentTally(tool: .claudeCode, state: .working, count: 1)])
        // Without one working, the most urgent state.
        #expect(
            AgentTally.byTool([session("c1", .claudeCode, .done), session("c2", .claudeCode, .needsInput)])
                == [AgentTally(tool: .claudeCode, state: .needsInput, count: 2)])
    }
    @Test func subagentsAloneCountOneAndNoSessionsNoTally() {
        #expect(
            AgentTally.byTool([
                session("s1", .gemini, .working, subagent: true), session("s2", .gemini, .done, subagent: true),
            ])
                == [AgentTally(tool: .gemini, state: .working, count: 1)])
        #expect(AgentTally.byTool([]).isEmpty)
    }
}
