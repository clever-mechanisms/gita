import Foundation

/// Display metadata Orca reports for one agent session or delegated subagent.
public struct AgentMetadata: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case session, subagent }

    public var role: Role
    public var agentName: String
    public var sessionName: String?
    public var taskTitle: String?
}
