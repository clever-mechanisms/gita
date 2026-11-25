import Foundation

/// What the in-place review shows of one pull request: its description, the submitted reviews and comments in time
/// order, the inline review threads, and what the signed-in account may do.
public struct PullRequestConversation: Sendable {
    /// GitHub's node id, which review mutations name.
    public var nodeID: String
    public var body: String
    public var author: String?
    public var createdAt: Date?
    public var lifecycle: PullRequestLifecycle
    public var isDraft: Bool
    public var baseBranch: String?
    public var headBranch: String?
    /// The head commit the diff and new review comments belong to.
    public var headOID: String
    public var reviewDecision: PullRequestStatusLabel.Review?
    public var viewer: String?
    /// Explicit `GH_CONFIG_DIR` profile the pull request was loaded with, or `nil` for `gh`'s default config.
    public var viewerProfile: GitHubConfigProfile?
    /// GitHub refuses approvals and change requests from a pull request's own author.
    public var viewerIsAuthor: Bool
    public var timeline: [ConversationEntry]
    public var threads: [ReviewThread]
    /// More reviews, comments or threads exist than were read.
    public var isTruncated: Bool
    /// Whether and how the account can merge it.
    public var merge = PullRequestMergeOptions()

    /// A pull request that is still open takes reviews.
    public var acceptsReviews: Bool { lifecycle == .open }
}

/// One review or conversation comment.
public struct ConversationEntry: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case comment
        case review(PullRequestStatusLabel.Review)
    }

    public var id: String
    public var kind: Kind
    public var author: String?
    public var body: String
    public var date: Date?
}

/// An inline discussion on one line of one file.
public struct ReviewThread: Identifiable, Sendable, Equatable {
    public var id: String
    public var path: String
    /// The line on the current diff; nil once the thread is outdated.
    public var line: Int?
    public var side: DiffSide
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [ThreadComment]
}

public struct ThreadComment: Identifiable, Sendable, Equatable {
    public var id: String
    public var author: String?
    public var body: String
    public var date: Date?
}

/// Which side of a diff a line comment is on: the base (removed lines) or the head (added and context lines).
public enum DiffSide: String, Sendable, Codable, Hashable {
    case left = "LEFT"
    case right = "RIGHT"
}
