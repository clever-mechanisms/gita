/// Agents told apart by tool, for places that show one mark per kind of agent (a collapsed tab group's chip).
public struct AgentTally: Sendable, Hashable {
    public var tool: AgentTool
    /// Working when any of this tool's sessions works (the mark turns), else the most urgent state.
    public var state: AgentState
    /// Its agents, subagents not counted (a tool seen only through subagents counts one).
    public var count: Int

    public init(tool: AgentTool, state: AgentState, count: Int) {
        self.tool = tool
        self.state = state
        self.count = count
    }

    /// One tally per tool present, in `AgentTool` order so marks keep their places as states change.
    public static func byTool(_ sessions: [AgentSession]) -> [Self] {
        AgentTool.allCases.compactMap { tool in
            let own = sessions.filter { $0.tool == tool }
            guard !own.isEmpty, let urgent = AgentSummary(own).state else { return nil }
            let state: AgentState = own.contains { $0.state == .working } ? .working : urgent
            return Self(tool: tool, state: state, count: max(1, own.filter { !$0.isSubagent }.count))
        }
    }
}
