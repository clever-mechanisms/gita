import Foundation

/// A numbered GitHub target whose repository is supplied by the destination checkout.
public enum TeleportTargetHint: Sendable, Hashable {
    case pullRequest(number: Int)
    case workflowRun(runID: Int64, jobID: Int64?)
}

public enum TeleportQuery: Sendable, Hashable {
    case deepLink(inner: TeleportTargetHint)
    case pullRequest(owner: String, repo: String, number: Int, sourceURL: URL?)
    case commit(owner: String?, repo: String?, sha: String, sourceURL: URL?)
    case workflowRun(owner: String, repo: String, runID: Int64, jobID: Int64?, sourceURL: URL?)
    case deployment(teamSlug: String?, projectName: String?, deploymentRef: String, sourceURL: URL?)
    case branch(owner: String?, repo: String?, name: String)
}

public struct ParsedTeleportInput: Sendable, Hashable {
    public let query: TeleportQuery
    public let workspaceHint: String?
    public let repoHint: String?
    public let rawInput: String

    public init(
        query: TeleportQuery,
        workspaceHint: String? = nil,
        repoHint: String? = nil,
        rawInput: String
    ) {
        self.query = query
        self.workspaceHint = workspaceHint
        self.repoHint = repoHint
        self.rawInput = rawInput
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.query, lhs.workspaceHint, lhs.repoHint, lhs.rawInput) == (
            rhs.query, rhs.workspaceHint, rhs.repoHint, rhs.rawInput
        )
    }
}

public struct TeleportRepositoryEntry: Sendable, Hashable {
    public let workspaceID: String
    public let workspaceTitle: String
    public let repoPath: URL
    public let displayName: String
    public let remoteURLs: [String]
    public let githubSlug: String?
    public let vercelProjectName: String?
    public let vercelTeamSlug: String?
    public let vercelProjectID: String?

    public init(
        workspaceID: String,
        workspaceTitle: String,
        repoPath: URL,
        displayName: String,
        remoteURLs: [String] = [],
        githubSlug: String? = nil,
        vercelProjectName: String? = nil,
        vercelTeamSlug: String? = nil,
        vercelProjectID: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.repoPath = repoPath
        self.displayName = displayName
        self.remoteURLs = remoteURLs
        self.githubSlug = githubSlug
        self.vercelProjectName = vercelProjectName
        self.vercelTeamSlug = vercelTeamSlug
        self.vercelProjectID = vercelProjectID
    }
}

public enum TeleportTarget: Sendable, Hashable {
    case pullRequest(number: Int, owner: String, repo: String, url: URL?)
    case commit(sha: String, url: URL?)
    case workflowRun(runID: Int64, jobID: Int64?, owner: String, repo: String, url: URL?)
    case deployment(reference: String, projectName: String?, url: URL?)
    case branch(name: String)
}

public struct TeleportDestination: Sendable, Hashable {
    public enum MatchReason: Sendable, Hashable {
        case githubRemote, vercelProject, localObject, localBranch, workspaceHint
    }

    public let workspaceID: String
    public let workspaceTitle: String
    public let repoPath: URL
    public let repoDisplayName: String
    public let target: TeleportTarget
    public let matchReason: MatchReason

    public init(
        workspaceID: String,
        workspaceTitle: String,
        repoPath: URL,
        repoDisplayName: String,
        target: TeleportTarget,
        matchReason: MatchReason
    ) {
        self.workspaceID = workspaceID
        self.workspaceTitle = workspaceTitle
        self.repoPath = repoPath
        self.repoDisplayName = repoDisplayName
        self.target = target
        self.matchReason = matchReason
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.workspaceID, lhs.workspaceTitle, lhs.repoPath) == (rhs.workspaceID, rhs.workspaceTitle, rhs.repoPath)
            && (lhs.repoDisplayName, lhs.target, lhs.matchReason) == (rhs.repoDisplayName, rhs.target, rhs.matchReason)
    }
}

public enum TeleportResolution: Sendable, Hashable {
    case resolved(TeleportDestination)
    case ambiguous([TeleportDestination])
    case notFound(ParsedTeleportInput)
}
