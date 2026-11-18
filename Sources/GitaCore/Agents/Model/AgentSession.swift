import Foundation

/// One agent session as the app shows it.
public struct AgentSession: Identifiable, Sendable, Hashable, Codable {
    /// `AgentSessionID`: `<tool>-<pid>` for processes, `<tool>-<session id>` for hook-only sessions.
    public var id: String
    public var tool: AgentTool
    public var pid: Int32?
    public var workingDirectory: URL
    /// The checkout the agent works in (a worktree root or the main checkout), from
    /// `git rev-parse --show-toplevel`.
    public var checkoutRoot: URL?
    /// The repository's main checkout, shared by all of its worktrees (`--git-common-dir` parent).
    public var repositoryRoot: URL?
    public var branch: String?
    public var state: AgentState
    public var stateSince: Date
    public var startedAt: Date?
    public var evidence: AgentEvidence
    /// Task title when a hook or Orca reports one.
    public var title: String?
    public var isSubagent: Bool
    /// The session that started this one (a subagent's parent), when that session is known.
    public var parentID: String?
    /// Set when a finished session has not been looked at yet (drives the "done" dot until seen).
    public var unseen: Bool

    public init(
        id: String, tool: AgentTool, pid: Int32?, workingDirectory: URL, checkoutRoot: URL? = nil,
        repositoryRoot: URL? = nil, branch: String? = nil, state: AgentState, stateSince: Date, startedAt: Date? = nil,
        evidence: AgentEvidence, title: String? = nil, isSubagent: Bool = false, parentID: String? = nil,
        unseen: Bool = false
    ) {
        self.id = id
        self.tool = tool
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.checkoutRoot = checkoutRoot
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.state = state
        self.stateSince = stateSince
        self.startedAt = startedAt
        self.evidence = evidence
        self.title = title
        self.isSubagent = isSubagent
        self.parentID = parentID
        self.unseen = unseen
    }
}
