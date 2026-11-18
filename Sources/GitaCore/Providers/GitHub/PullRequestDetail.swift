import Foundation

/// A pull request's detail page: lifecycle, branches, the latest reviews, requested reviewers and head checks.
public struct PullRequestDetail: Sendable {
    public var number: Int
    public var title: String
    public var author: String?
    public var lifecycle: PullRequestLifecycle
    public var baseBranch: String?
    public var headBranch: String?
    public var reviewDecision: PullRequestStatusLabel.Review?
    public var mergeability: PullRequestMergeability?
    public var url: URL?
    public var checks: ProviderPage<ProviderCheck>
    public var reviews: ProviderPage<ProviderReview>
    public var requestedReviewers: ProviderPage<ProviderReviewer>
}

/// One check run or status context on the head commit.
public struct ProviderCheck: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var workflow: String?
    public var state: SignalState
    public var url: URL?
}

public struct ProviderReview: Identifiable, Sendable {
    public var id: String
    public var author: String?
    public var status: PullRequestStatusLabel.Review
}

/// Whether an open pull request merges cleanly; nil on the detail while GitHub is still computing it.
public enum PullRequestMergeability: Sendable, CaseIterable {
    case mergeable, conflicting

    public var localizedTitle: String {
        switch self {
        case .mergeable: String(localized: "Mergeable")
        case .conflicting: String(localized: "Conflicts")
        }
    }
}

public struct ProviderReviewer: Identifiable, Sendable {
    public var id: String
    public var name: String
}
