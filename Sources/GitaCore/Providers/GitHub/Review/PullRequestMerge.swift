import Foundation

/// How a pull request goes into its base branch, as GitHub offers it: a merge commit, one squashed commit, or the
/// commits rebased onto the base.
public enum PullRequestMergeMethod: String, Sendable, CaseIterable {
    case merge = "MERGE"
    case squash = "SQUASH"
    case rebase = "REBASE"

    /// GitHub's button title: "Create a merge commit", "Squash and merge", "Rebase and merge".
    public var localizedTitle: String {
        switch self {
        case .merge: String(localized: "Create a merge commit")
        case .squash: String(localized: "Squash and merge")
        case .rebase: String(localized: "Rebase and merge")
        }
    }

    /// What happens to the branch's `commits`, as GitHub explains each method.
    public func explanation(commits: Int) -> String {
        switch self {
        case .merge:
            String(localized: "All commits from this branch will be added to the base branch via a merge commit.")
        case .squash: String(localized: "The \(commits) commits from this branch will be added to the base branch.")
        case .rebase:
            String(
                localized: "The \(commits) commits from this branch will be rebased and added to the base branch.")
        }
    }
}

/// Whether and how the signed-in account can merge one pull request: the methods the repository allows, the one
/// GitHub suggests, and what GitHub knows about conflicts.
public struct PullRequestMergeOptions: Sendable, Equatable {
    /// GitHub's `mergeable`: conflicts are only known once GitHub has computed them.
    public enum Mergeability: Sendable, Equatable {
        case mergeable
        case conflicting
        case unknown
    }

    /// The methods the repository allows, in GitHub's order.
    public var methods: [PullRequestMergeMethod]
    public var preferred: PullRequestMergeMethod?
    /// The account has write access to the repository.
    public var viewerCanMerge: Bool
    public var mergeability: Mergeability
    public var commitCount: Int

    public init(
        methods: [PullRequestMergeMethod] = [], preferred: PullRequestMergeMethod? = nil, viewerCanMerge: Bool = false,
        mergeability: Mergeability = .unknown, commitCount: Int = 0
    ) {
        self.methods = methods
        self.preferred = preferred
        self.viewerCanMerge = viewerCanMerge
        self.mergeability = mergeability
        self.commitCount = commitCount
    }

    /// The method a merge starts with: GitHub's suggestion when the repository still allows it, else the first.
    public var defaultMethod: PullRequestMergeMethod? {
        preferred.flatMap { methods.contains($0) ? $0 : nil } ?? methods.first
    }
}
