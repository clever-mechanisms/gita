import Foundation

public enum ProviderKind: String, Sendable, Codable { case github, vercel, orca }
public enum SignalState: String, Sendable, Codable { case success, failure, running, pending, cancelled, neutral }
public struct PullRequestSummary: Sendable, Hashable {
    public var number: Int
    public var lifecycle: PullRequestLifecycle
    public var isDraft: Bool
    /// Aggregate checks for headCommit, independent of the PR lifecycle; nil when GitHub reported no rollup.
    public var checksState: PullRequestStatusLabel.Checks?
    public var headCommit: String?
    public var mergeCommit: String?
    /// GitHub logins (who opened / who merged) and when; nil when the provider didn't report them.
    public var author: String?
    public var mergedBy: String?
    public var createdAt: Date?
    public var mergedAt: Date?
    /// True when the signed-in `gh` user is a requested reviewer.
    public var reviewRequestedFromViewer: Bool
    /// The review and checks label of an open, ready pull request; nil otherwise (the item's `detail` says it).
    public var status: PullRequestStatusLabel?
    public init(
        number: Int, lifecycle: PullRequestLifecycle, isDraft: Bool,
        checksState: PullRequestStatusLabel.Checks? = nil, headCommit: String? = nil, mergeCommit: String? = nil,
        author: String? = nil, mergedBy: String? = nil, createdAt: Date? = nil, mergedAt: Date? = nil,
        reviewRequestedFromViewer: Bool = false, status: PullRequestStatusLabel? = nil
    ) {
        self.number = number
        self.lifecycle = lifecycle
        self.isDraft = isDraft
        self.checksState = checksState
        self.headCommit = headCommit
        self.mergeCommit = mergeCommit
        self.author = author
        self.mergedBy = mergedBy
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.reviewRequestedFromViewer = reviewRequestedFromViewer
        self.status = status
    }
}
public struct ProviderItem: Identifiable, Sendable, Hashable {
    public var id: String
    public var provider: ProviderKind
    public var category: String
    public var title: String
    public var state: SignalState
    public var detail: String
    public var commit: String?
    public var branch: String?
    public var url: URL?
    public var date: Date?
    public var worktreePath: String?
    public var kind: ProviderItemKind
    public var target: ProviderTarget?
    public var agent: AgentMetadata?
    public var pullRequest: PullRequestSummary?
    /// Stable GitHub workflow identity, independent of its editable display name.
    public var workflowDatabaseID: Int64?
    public var workflowRunNumber: Int?
    /// Provider-reported start of this attempt, or deployment creation time.
    public var startedAt: Date?
    public var deployment: DeploymentSummary?
    public init(
        id: String, provider: ProviderKind, category: String, title: String, state: SignalState, detail: String = "",
        commit: String? = nil, branch: String? = nil, url: URL? = nil, date: Date? = nil, worktreePath: String? = nil,
        kind: ProviderItemKind = .other, target: ProviderTarget? = nil, agent: AgentMetadata? = nil,
        pullRequest: PullRequestSummary? = nil, workflowDatabaseID: Int64? = nil, deployment: DeploymentSummary? = nil,
        workflowRunNumber: Int? = nil, startedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.category = category
        self.title = title
        self.state = state
        self.detail = detail
        self.commit = commit
        self.branch = branch
        self.url = url
        self.date = date
        self.worktreePath = worktreePath
        self.kind = kind
        self.target = target
        self.agent = agent
        self.pullRequest = pullRequest
        self.workflowDatabaseID = workflowDatabaseID
        self.deployment = deployment
        self.workflowRunNumber = workflowRunNumber
        self.startedAt = startedAt
    }
}
public struct ProviderReport: Sendable {
    public var provider: ProviderKind
    public var items: [ProviderItem]
    public var status: ProviderStatus
    public var diagnostic: String?
    public var checkedAt: Date
    /// Validated hosted repository/project identity, independent of the local worktree.
    public var sourceID: String?
    /// Vercel only: live production, branch preview URLs and preview comments.
    public var vercel: VercelContext?
    /// Vercel only: errors, CI, rollout, Agent Runs, alerts and platform status.
    public var vercelSignals: VercelSignals?
    public init(
        provider: ProviderKind, items: [ProviderItem], status: ProviderStatus, diagnostic: String? = nil,
        checkedAt: Date = Date(), sourceID: String? = nil
    ) {
        self.provider = provider
        self.items = items
        self.status = status
        self.diagnostic = diagnostic
        self.checkedAt = checkedAt
        self.sourceID = sourceID
    }
}
