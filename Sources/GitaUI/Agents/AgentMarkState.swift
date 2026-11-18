import GitaCore

/// Which agent sits somewhere and what it is doing: all a mark needs to draw itself.
struct AgentMarkState: Hashable {
    var tool: AgentTool
    var state: AgentState
    init(tool: AgentTool, state: AgentState) {
        self.tool = tool
        self.state = state
    }
    init(_ session: AgentSession) {
        tool = session.tool
        state = session.state
    }
}
