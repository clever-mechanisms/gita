import Foundation
import Testing

@testable import GitaCore

/// Orca's agent states go through one typed table: what the parser writes is what `reportedAgentState` reads back
/// and what `ProviderText` titles.
@Suite struct OrcaAgentStateTests {
    private static let path = OrcaAgentParser.normalizedPath("/tmp/gita-orca-states")

    /// Orca's word (state, main agent outcome, live terminal) → the item's token, signal state and reported state.
    struct Row: Sendable {
        var raw: String
        var outcome: String?
        var live: Bool
        var token: String
        var signal: SignalState
        var state: AgentState?

        init(
            _ raw: String, _ outcome: String?, _ live: Bool, _ token: String, _ signal: SignalState,
            _ state: AgentState?
        ) {
            (self.raw, self.outcome, self.live, self.token, self.signal, self.state) =
                (raw, outcome, live, token, signal, state)
        }
    }

    static let table: [Row] = [
        Row("working", nil, true, "Working", .running, .working),
        Row("busy", nil, true, "Working", .running, .working),
        Row("blocked", nil, true, "Needs attention", .pending, .needsInput),
        Row("needs_input", nil, true, "Needs attention", .pending, .needsInput),
        Row("done", nil, true, "Idle", .neutral, .idle),
        Row("done", "error", true, "Failed", .failure, .idle),
        Row("idle", "cancellation", true, "Cancelled", .cancelled, .idle),
        Row("error", nil, true, "Failed", .failure, .idle),
        Row("exited", nil, true, "Stopped", .neutral, nil),
        Row("brand-new", nil, true, "Connected", .neutral, nil),
        Row("working", nil, false, "Unverified", .neutral, nil),
    ]

    private static func payload(raw: String, outcome: String?, live: Bool) -> Data {
        let outcomeField = outcome.map { ",\"outcome\":\"\($0)\"" } ?? ""
        return Data(
            """
            {"ok":true,"result":{"worktrees":[{"path":"\(path)","hostId":"local","terminalVerdict":"live","agents":[
            {"paneKey":"one","agentType":"claude","hasLivePty":\(live),\
            "mainAgent":{"state":"\(raw)"\(outcomeField)}}]}]}}
            """.utf8)
    }

    @Test(arguments: table.indices)
    func parsedSessionsReportTheirState(_ index: Int) throws {
        let row = Self.table[index]
        let tree = GitWorktree(
            path: Self.path, branch: "main", head: "abcd", isBare: false, isLocked: false, isPrunable: false)
        let page = try OrcaAgentParser.page(
            Self.payload(raw: row.raw, outcome: row.outcome, live: row.live), worktrees: [tree])
        let item = try #require(page.items.first)
        #expect(item.detail == row.token)
        #expect(item.state == row.signal)
        #expect(item.reportedAgentState == row.state)
        #expect(item.reportedAgentTool == .claudeCode)
    }

    @Test func everyTokenIsTitledAndReadBack() {
        for state in OrcaAgentState.allCases {
            #expect(ProviderText.status(state.rawValue) == state.localizedTitle, "\(state)")
            #expect(OrcaAgentState(rawValue: state.rawValue) == state)
        }
        #expect(ProviderText.status("Cancelled") == ProviderStatus.cancelled.localizedTitle)
        #expect(ProviderText.status("Failed") == VercelSignals.CIStatus.failed.localizedTitle)
    }

    @Test func finishedSubagentsAreTitledFinished() throws {
        let data = Data(
            """
            {"ok":true,"result":{"worktrees":[{"path":"\(Self.path)","hostId":"local","terminalVerdict":"live",\
            "agents":[{"paneKey":"one","agentType":"codex","hasLivePty":true,"state":"working",\
            "subagentObservation":"live","subagents":[{"id":"a","state":"completed"},{"id":"b","state":"busy"}]}]}]}}
            """.utf8)
        let tree = GitWorktree(
            path: Self.path, branch: "main", head: "abcd", isBare: false, isLocked: false, isPrunable: false)
        let page = try OrcaAgentParser.page(data, worktrees: [tree])
        let subagents = page.items.filter { $0.agent?.role == .subagent }
        #expect(subagents.map(\.detail) == ["Finished", "Working"])
        #expect(subagents.map(\.state) == [.neutral, .running])
        // A subagent's state is never a session report.
        #expect(subagents.allSatisfy { $0.reportedAgentState == nil })
    }
}
