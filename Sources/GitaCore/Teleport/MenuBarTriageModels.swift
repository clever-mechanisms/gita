import Foundation

public struct AgentTerminalJumpTarget: Sendable, Hashable {
    public let workspaceID: String
    public let repoPath: URL
    public let tabID: String?
    public let sessionID: String
    public let agentName: String

    public init(
        workspaceID: String,
        repoPath: URL,
        tabID: String? = nil,
        sessionID: String,
        agentName: String
    ) {
        self.workspaceID = workspaceID
        self.repoPath = repoPath
        self.tabID = tabID
        self.sessionID = sessionID
        self.agentName = agentName
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.workspaceID, lhs.repoPath, lhs.tabID) == (rhs.workspaceID, rhs.repoPath, rhs.tabID)
            && (lhs.sessionID, lhs.agentName) == (rhs.sessionID, rhs.agentName)
    }
}

public enum TriageActionKind: Sendable, Hashable {
    case approvePullRequest(number: Int, owner: String, repo: String, repoPath: URL, account: GitHubAccountUse)
    case rerunFailedCIJobs(runID: Int64, owner: String, repo: String, repoPath: URL, account: GitHubAccountUse)
    case promoteVercelDeployment(reference: String, projectName: String, scope: String?, repoPath: URL)
    case rollbackVercelDeployment(reference: String, projectName: String, scope: String?, repoPath: URL)
    case jumpToAgentTerminal(AgentTerminalJumpTarget)

    var requiresConfirmation: Bool {
        switch self {
        case .approvePullRequest, .promoteVercelDeployment, .rollbackVercelDeployment: true
        case .rerunFailedCIJobs, .jumpToAgentTerminal: false
        }
    }
}

public struct TriageItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let contextBadge: String
    public let signalState: SignalState
    public let kind: TriageActionKind
    public let requiresConfirmation: Bool

    public init(
        id: String, title: String, subtitle: String, contextBadge: String, signalState: SignalState,
        kind: TriageActionKind
    ) {
        self.init(
            id: id, title: title, subtitle: subtitle, contextBadge: contextBadge, signalState: signalState,
            kind: kind, requiresConfirmation: kind.requiresConfirmation)
    }

    public init(
        id: String,
        title: String,
        subtitle: String,
        contextBadge: String,
        signalState: SignalState,
        kind: TriageActionKind,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.contextBadge = contextBadge
        self.signalState = signalState
        self.kind = kind
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum TriageActionState: Equatable, Sendable {
    case idle, confirming, running
    case succeeded(String)
    case failed(String)
}

public struct TriageActionError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}
