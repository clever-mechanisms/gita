import Foundation

public enum ProviderDetail: Sendable {
    case pullRequest(PullRequestDetail)
    case workflowRun(WorkflowRunDetail)
    case deployment(DeploymentDetail)
}

/// One bounded detail read for a provider item.
public struct ProviderDetailReport: Sendable {
    public var target: ProviderTarget
    public var content: ProviderDetail?
    public var status: ProviderStatus
    public var diagnostic: String?

    public init(
        target: ProviderTarget, content: ProviderDetail? = nil, status: ProviderStatus, diagnostic: String? = nil
    ) {
        self.target = target
        self.content = content
        self.status = status
        self.diagnostic = diagnostic
    }

    init(target: ProviderTarget, failure: ProviderFailure) {
        self.init(target: target, status: failure.status, diagnostic: failure.diagnostic)
    }
}
