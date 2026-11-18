import Foundation

/// Reads the review window's conversation query. The repository and pull request must be the ones asked for;
/// rows without an id are dropped, pending reviews (only ever the viewer's own unsent draft) are left out, and a
/// review that only carried line comments shows in its threads rather than as an empty entry.
enum GitHubConversationParser {
    typealias Envelope = GitHubGraphQLEnvelope<Repository>

    struct Repository: Decodable, Sendable {
        var nameWithOwner: String
        var viewerPermission: String?
        var viewerDefaultMergeMethod: String?
        @DecodedDefault<DefaultFalse> var mergeCommitAllowed: Bool
        @DecodedDefault<DefaultFalse> var squashMergeAllowed: Bool
        @DecodedDefault<DefaultFalse> var rebaseMergeAllowed: Bool
        var pullRequest: PullRequest?
    }

    struct PullRequest: Decodable, Sendable {
        var id: String
        var number: Int
        var title: String
        var body: String?
        var state: String?
        @DecodedDefault<DefaultFalse> var isDraft: Bool
        var baseRefName: String?
        var headRefName: String?
        var headRefOid: String?
        var reviewDecision: String?
        @DecodedDefault<DefaultFalse> var viewerDidAuthor: Bool
        var createdAt: String?
        var author: GitHubActor?
        var mergeable: String?
        var commits: GitHubConnection<GitHubCommitNode>?
        var reviews: GitHubConnection<Review>?
        var comments: GitHubConnection<Comment>?
        var reviewThreads: GitHubConnection<Thread>?
    }

    struct Review: Decodable, Sendable {
        var id: String?
        var author: GitHubActor?
        var state: String?
        var body: String?
        var submittedAt: String?
    }

    struct Comment: Decodable, Sendable {
        var id: String?
        var author: GitHubActor?
        var body: String?
        var createdAt: String?
    }

    struct Thread: Decodable, Sendable {
        var id: String?
        var path: String?
        var line: Int?
        var originalLine: Int?
        var diffSide: String?
        @DecodedDefault<DefaultFalse> var isResolved: Bool
        @DecodedDefault<DefaultFalse> var isOutdated: Bool
        var comments: GitHubConnection<Comment>?
    }

    static func conversation(
        _ envelope: Envelope, repository: GitHubRepository, number: Int
    ) throws
        -> PullRequestConversation
    {
        guard let repo = envelope.repository, repo.nameWithOwner.lowercased() == repository.nameWithOwner.lowercased(),
            let row = repo.pullRequest, row.number == number, !row.id.isEmpty,
            let head = ProviderValidation.nonempty(row.headRefOid), isObjectID(head)
        else { throw ProviderResponseError.shape }
        let timeline = (reviews(row.reviews) + comments(row.comments)).sorted { left, right in
            (left.date ?? .distantPast) < (right.date ?? .distantPast)
        }
        let truncated = [row.reviews?.overflows, row.comments?.overflows, row.reviewThreads?.overflows].contains {
            $0 ?? true
        }
        var conversation = PullRequestConversation(
            nodeID: row.id, body: row.body ?? "",
            author: row.author?.validLogin, createdAt: ProviderDates.iso8601(row.createdAt),
            lifecycle: PullRequestLifecycle(gitHub: row.state), isDraft: row.isDraft,
            baseBranch: ProviderValidation.bounded(row.baseRefName),
            headBranch: ProviderValidation.bounded(row.headRefName), headOID: head,
            reviewDecision: GitHubPullRequestState.review(row.reviewDecision),
            viewer: envelope.data?.viewer?.validLogin,
            viewerIsAuthor: row.viewerDidAuthor, timeline: timeline, threads: threads(row.reviewThreads),
            isTruncated: truncated)
        conversation.merge = merge(repo, row)
        return conversation
    }

    /// Merging needs write access; the methods are the ones the repository allows, in GitHub's order.
    static func merge(_ repo: Repository, _ row: PullRequest) -> PullRequestMergeOptions {
        let allowed: [PullRequestMergeMethod: Bool] = [
            .merge: repo.mergeCommitAllowed, .squash: repo.squashMergeAllowed, .rebase: repo.rebaseMergeAllowed,
        ]
        let mergeability: PullRequestMergeOptions.Mergeability =
            switch row.mergeable {
            case "MERGEABLE": .mergeable
            case "CONFLICTING": .conflicting
            default: .unknown
            }
        return PullRequestMergeOptions(
            methods: PullRequestMergeMethod.allCases.filter { allowed[$0] == true },
            preferred: repo.viewerDefaultMergeMethod.flatMap(PullRequestMergeMethod.init(rawValue:)),
            viewerCanMerge: ["ADMIN", "MAINTAIN", "WRITE"].contains(repo.viewerPermission ?? ""),
            mergeability: mergeability, commitCount: max(0, row.commits?.totalCount ?? 0))
    }

    private static func reviews(_ connection: GitHubConnection<Review>?) -> [ConversationEntry] {
        rows(connection).compactMap { review in
            guard let id = ProviderValidation.nonempty(review.id) else { return nil }
            let status = GitHubPullRequestState.review(review.state) ?? .unknown
            let body = review.body ?? ""
            if status == .pending || status == .commented && body.isEmpty { return nil }
            return ConversationEntry(
                id: id, kind: .review(status), author: review.author?.validLogin, body: body,
                date: ProviderDates.iso8601(review.submittedAt))
        }
    }

    private static func comments(_ connection: GitHubConnection<Comment>?) -> [ConversationEntry] {
        threadComments(connection).map {
            ConversationEntry(id: $0.id, kind: .comment, author: $0.author, body: $0.body, date: $0.date)
        }
    }

    private static func threadComments(_ connection: GitHubConnection<Comment>?) -> [ThreadComment] {
        rows(connection).compactMap { comment in
            guard let id = ProviderValidation.nonempty(comment.id) else { return nil }
            return ThreadComment(
                id: id, author: comment.author?.validLogin, body: comment.body ?? "",
                date: ProviderDates.iso8601(comment.createdAt))
        }
    }

    private static func threads(_ connection: GitHubConnection<Thread>?) -> [ReviewThread] {
        rows(connection).compactMap { thread in
            guard let id = ProviderValidation.nonempty(thread.id), let path = ProviderValidation.nonempty(thread.path)
            else { return nil }
            let comments = threadComments(thread.comments)
            guard !comments.isEmpty else { return nil }
            return ReviewThread(
                id: id, path: path, line: thread.line.flatMap { $0 > 0 ? $0 : nil },
                side: DiffSide(rawValue: thread.diffSide ?? "") ?? .right, isResolved: thread.isResolved,
                isOutdated: thread.isOutdated || thread.line == nil, comments: comments)
        }
    }

    private static func rows<Row>(_ connection: GitHubConnection<Row>?) -> [Row] {
        connection?.nodes?.rows.compactMap { $0 } ?? []
    }

    /// A full hexadecimal commit id (SHA-1 or SHA-256).
    static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension GitHubConnection {
    /// GitHub holds more rows than this page returned, or the page is missing.
    fileprivate var overflows: Bool {
        guard let rows = nodes?.rows else { return true }
        return (totalCount ?? rows.count) > rows.count
    }
}
