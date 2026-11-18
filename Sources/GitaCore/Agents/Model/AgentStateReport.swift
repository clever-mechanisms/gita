import Foundation

/// A session state another app reports for an agent in one checkout (Orca, for the agents in its terminals).
public struct AgentStateReport: Sendable, Hashable {
    public var tool: AgentTool
    /// The checkout's root, as Git reports it (symlinks resolved).
    public var checkout: String
    public var state: AgentState

    public init(tool: AgentTool, checkout: String, state: AgentState) {
        self.tool = tool
        self.checkout = checkout
        self.state = state
    }
}

extension ProviderItem {
    /// The agent session's state as Orca reports it; nil for anything else, and for a session Orca cannot verify
    /// (no live terminal) or reports in a way that is not a state.
    public var reportedAgentState: AgentState? {
        guard provider == .orca, kind == .agent, agent?.role == .session else { return nil }
        return OrcaAgentState(rawValue: detail)?.agentState
    }

    /// The tool the session runs, matched by Orca's agent name ("Claude Code", "Codex", "Cursor", "Gemini"…); nil for
    /// an agent Gitā does not detect.
    public var reportedAgentTool: AgentTool? {
        guard let name = agent?.agentName.lowercased() else { return nil }
        if name == "cursor" { return .cursorAgent }
        return AgentTool.allCases.first { $0.displayName.lowercased() == name || $0.rawValue.lowercased() == name }
    }
}
