import Foundation

/// The pull request list: the 30 most recently updated pull requests across all states, as provider items.
enum GitHubPullRequestSummaryParser {
    typealias Envelope = GitHubGraphQLEnvelope<GitHubPullRequestRepository>

    static let pageSize = 30

    static func items(_ envelope: Envelope, repository: GitHubRepository) throws -> ProviderParsed<[ProviderItem]> {
        let repo = try GitHubPullRequestDetailParser.checkedRepository(envelope, expected: repository)
        guard let connection = repo.pullRequests, let nodes = connection.nodes?.rows else {
            throw ProviderResponseError.shape
        }
        guard connection.totalCount.map({ $0 >= nodes.count }) ?? true else { throw ProviderResponseError.shape }
        let viewer = envelope.data?.viewer?.validLogin
        var numbers = Set<Int>()
        var staleHead = false
        let items = try nodes.prefix(pageSize).compactMap { row -> ProviderItem? in
            guard let row else { return nil }
            guard row.number > 0, row.number <= Int(Int32.max), numbers.insert(row.number).inserted else {
                throw ProviderResponseError.shape
            }
            if row.tip?.oid != row.headRefOid { staleHead = true }
            return item(row, repository: repository, viewer: viewer)
        }
        let incomplete =
            envelope.hasErrors || connection.totalCount == nil || connection.pageInfo == nil
            || nodes.count > pageSize || nodes.contains(where: { $0 == nil })
        return ProviderParsed(value: items, partial: incomplete || staleHead)
    }

    private static func item(
        _ row: GitHubPullRequestNode, repository: GitHubRepository, viewer: String?
    ) -> ProviderItem {
        let checks = GitHubPullRequestState.checks(row.currentRollup?.state)
        let (state, token, label) = GitHubPullRequestState.summary(row, checks: checks)
        return ProviderItem(
            id: "github:pr:\(row.number)", provider: .github, category: String(localized: "Pull request"),
            title: String(localized: "#\(row.number) \(row.title)"), state: state, detail: token,
            commit: ProviderValidation.nonempty(row.headRefOid), branch: ProviderValidation.nonempty(row.headRefName),
            url: ProviderValidation.safeWebURL(row.url), date: ProviderDates.iso8601(row.updatedAt),
            kind: .pullRequest, target: .pullRequest(repository: repository.nameWithOwner, number: row.number),
            pullRequest: summary(row, checks: checks, viewer: viewer, status: label))
    }

    private static func summary(
        _ row: GitHubPullRequestNode, checks: PullRequestStatusLabel.Checks?, viewer: String?,
        status: PullRequestStatusLabel?
    ) -> PullRequestSummary {
        let lifecycle = PullRequestLifecycle(gitHub: row.state)
        let merged = lifecycle == .merged
        return PullRequestSummary(
            number: row.number, lifecycle: lifecycle, isDraft: row.isDraft,
            checksState: checks,
            headCommit: ProviderValidation.nonempty(row.headRefOid),
            mergeCommit: merged ? ProviderValidation.nonempty(row.mergeCommit?.oid) : nil,
            author: row.author?.validLogin, mergedBy: merged ? row.mergedBy?.validLogin : nil,
            createdAt: ProviderDates.iso8601(row.createdAt),
            mergedAt: merged ? ProviderDates.iso8601(row.mergedAt) : nil,
            reviewRequestedFromViewer: lifecycle == .open && isRequested(row, from: viewer), status: status)
    }

    /// Whether the signed-in account is among the requested reviewers; never guessed without a viewer.
    private static func isRequested(_ row: GitHubPullRequestNode, from viewer: String?) -> Bool {
        guard let viewer = viewer?.lowercased() else { return false }
        return (row.reviewRequests?.nodes?.rows ?? []).contains {
            $0?.requestedReviewer?.login?.lowercased() == viewer
        }
    }
}
