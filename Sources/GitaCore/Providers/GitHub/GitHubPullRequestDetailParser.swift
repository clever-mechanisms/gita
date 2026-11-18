import Foundation

/// One pull request's detail: the first 50 head checks, latest reviews and requested reviewers, each verified by its
/// provider identity. A connection GitHub did not return is reported as partial, never as empty.
enum GitHubPullRequestDetailParser {
    typealias Envelope = GitHubGraphQLEnvelope<GitHubPullRequestRepository>

    static let pageSize = 50

    static func detail(
        _ envelope: Envelope, repository: GitHubRepository, number: Int
    ) throws
        -> ProviderParsed<PullRequestDetail>
    {
        let repo = try checkedRepository(envelope, expected: repository)
        guard let row = repo.pullRequest, row.number == number, number > 0 else { throw ProviderResponseError.shape }
        let checks = try checksPage(row, envelopeHasErrors: envelope.hasErrors)
        let reviews = try reviewsPage(row)
        let reviewers = try reviewersPage(row)
        let detail = PullRequestDetail(
            number: row.number, title: row.title, author: row.author?.login,
            lifecycle: PullRequestLifecycle(gitHub: row.state), baseBranch: row.baseRefName,
            headBranch: row.headRefName, reviewDecision: GitHubPullRequestState.review(row.reviewDecision),
            mergeability: GitHubPullRequestState.mergeability(row.mergeable),
            url: ProviderValidation.safeWebURL(row.url),
            checks: checks.value, reviews: reviews.value, requestedReviewers: reviewers.value)
        let partial = envelope.hasErrors || checks.partial || reviews.partial || reviewers.partial
        return ProviderParsed(value: detail, partial: partial)
    }

    static func checkedRepository(
        _ envelope: Envelope, expected: GitHubRepository
    ) throws
        -> GitHubPullRequestRepository
    {
        guard let repo = envelope.repository,
            repo.nameWithOwner.lowercased() == expected.nameWithOwner.lowercased()
        else { throw ProviderResponseError.shape }
        return repo
    }

    // MARK: Connections

    private static func checksPage(
        _ row: GitHubPullRequestNode, envelopeHasErrors: Bool
    ) throws
        -> ProviderParsed<ProviderPage<ProviderCheck>>
    {
        if let contexts = row.currentRollup?.contexts {
            return try page(contexts.nodes, total: try checkTotal(contexts), info: contexts.pageInfo, transform: check)
        }
        // Known empty: the current head has no rollup at all (no checks configured).
        if !envelopeHasErrors, let head = ProviderValidation.nonempty(row.headRefOid), let tip = row.tip,
            tip.oid == head, tip.statusCheckRollup == nil
        {
            return ProviderParsed(value: ProviderPage(items: [], total: 0), partial: false)
        }
        return ProviderParsed(value: ProviderPage(items: []), partial: true)
    }

    private static func checkTotal(_ contexts: GitHubCheckContexts) throws -> Int? {
        guard let checks = contexts.checkRunCount, let statuses = contexts.statusContextCount else { return nil }
        let range = 0...Int(Int32.max)
        guard range.contains(checks), range.contains(statuses) else { throw ProviderResponseError.shape }
        return checks + statuses
    }

    private static func check(_ row: GitHubCheckNode) throws -> ProviderCheck {
        guard let id = ProviderValidation.nonempty(row.id), ["CheckRun", "StatusContext"].contains(row.typename)
        else { throw ProviderResponseError.shape }
        return ProviderCheck(
            id: id, name: row.name ?? row.context ?? String(localized: "Check"),
            workflow: row.checkSuite?.workflowRun?.workflow?.name,
            state: GitHubSignal.state(status: row.status ?? row.state, conclusion: row.conclusion),
            url: ProviderValidation.safeWebURL(row.detailsUrl ?? row.targetUrl))
    }

    private static func reviewsPage(_ row: GitHubPullRequestNode) throws -> ProviderParsed<ProviderPage<ProviderReview>>
    {
        guard let connection = row.latestReviews else {
            return ProviderParsed(value: ProviderPage(items: []), partial: true)
        }
        return try page(connection.nodes, total: connection.totalCount, info: connection.pageInfo) { review in
            guard !review.id.isEmpty else { throw ProviderResponseError.shape }
            return ProviderReview(
                id: review.id, author: review.author?.login,
                status: GitHubPullRequestState.review(review.state) ?? .unknown)
        }
    }

    private static func reviewersPage(
        _ row: GitHubPullRequestNode
    ) throws
        -> ProviderParsed<ProviderPage<ProviderReviewer>>
    {
        guard let connection = row.reviewRequests else {
            return ProviderParsed(value: ProviderPage(items: []), partial: true)
        }
        return try page(connection.nodes, total: connection.totalCount, info: connection.pageInfo) { request in
            try request.requestedReviewer.flatMap(reviewer)
        }
    }

    /// Users and bots by login, teams as `org/slug`; other reviewer kinds are skipped.
    private static func reviewer(_ reviewer: GitHubReviewRequestNode.Reviewer) throws -> ProviderReviewer? {
        guard let id = ProviderValidation.nonempty(reviewer.id) else { throw ProviderResponseError.shape }
        switch reviewer.typename {
        case "User", "Bot":
            guard let login = ProviderValidation.nonempty(reviewer.login) else { throw ProviderResponseError.shape }
            return ProviderReviewer(id: id, name: login)
        case "Team":
            guard let slug = ProviderValidation.nonempty(reviewer.slug) else { throw ProviderResponseError.shape }
            return ProviderReviewer(
                id: id, name: reviewer.organization?.login.map { $0 + "/" + slug } ?? reviewer.name ?? slug)
        default: return nil
        }
    }

    /// The first `pageSize` rows with unique ids. Missing totals, page info or rows make the page partial.
    private static func page<Row, Element: Identifiable & Sendable>(
        _ nodes: GitHubNodes<Row>?, total: Int?, info: GitHubPageInfo?, transform: (Row) throws -> Element?
    ) throws -> ProviderParsed<ProviderPage<Element>> where Element.ID: Hashable {
        guard let rows = nodes?.rows else { return ProviderParsed(value: ProviderPage(items: []), partial: true) }
        guard total.map({ $0 >= rows.count }) ?? true else { throw ProviderResponseError.shape }
        let items = try rows.prefix(pageSize).compactMap { row in try row.flatMap(transform) }
        guard Set(items.map(\.id)).count == items.count else { throw ProviderResponseError.shape }
        let overflow = rows.count > pageSize
        let hasMore = info?.hasNextPage == true || overflow || (total ?? rows.count) > rows.count
        let incomplete = info == nil || total == nil || overflow || items.count != min(rows.count, pageSize)
        return ProviderParsed(value: ProviderPage(items: items, total: total, hasMore: hasMore), partial: incomplete)
    }
}
