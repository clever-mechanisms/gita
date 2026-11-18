import Foundation

/// The selective shapes of the GraphQL responses Gita reads. Bodies, logs and commands are never decoded.
struct GitHubGraphQLEnvelope<Repository: Decodable & Sendable>: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        var repository: Repository?
        var viewer: GitHubActor?
    }
    /// One GraphQL error. Only its machine-readable `type` is used, plus whether the message names SAML
    /// enforcement (GitHub types that refusal `FORBIDDEN` too); the message itself never leaves this decoder.
    struct Failure: Decodable, Sendable {
        var type: String?
        var mentionsSAML: Bool

        private enum CodingKeys: String, CodingKey { case type, message }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            let message = try? container.decodeIfPresent(String.self, forKey: .message)
            mentionsSAML = message?.range(of: "SAML", options: .caseInsensitive) != nil
        }
    }

    var data: Payload?
    @DecodedDefault<DefaultEmpty<Failure>> var errors: [Failure]

    var hasErrors: Bool { !errors.isEmpty }
    var repository: Repository? { data?.repository }

    /// Why GitHub did not show the repository to this account, from the errors' types; nil when the repository came
    /// back or the errors are of another kind.
    var accessProblem: GitHubAccessProblem? {
        guard repository == nil else { return nil }
        if errors.contains(where: { $0.type == "FORBIDDEN" && $0.mentionsSAML }) { return .ssoRequired }
        if errors.contains(where: { $0.type == "NOT_FOUND" || $0.type == "FORBIDDEN" }) { return .notVisible }
        return nil
    }
}

/// Why a repository is hidden from the account that asked: another signed-in account may see it.
enum GitHubAccessProblem: Sendable, Hashable {
    /// GitHub answered "not found" or "forbidden".
    case notVisible
    /// The organization requires this account to authorize single sign-on first.
    case ssoRequired
}

struct GitHubActor: Decodable, Sendable {
    var login: String?

    private static let maximumLogin = 64

    /// GitHub logins are ASCII letters, digits or hyphens; bots end in `[bot]`.
    var validLogin: String? {
        guard let value = login, !value.isEmpty, value.utf8.count <= Self.maximumLogin,
            ProviderValidation.consists(value, of: ProviderValidation.loginCharacters)
        else { return nil }
        return value
    }
}

/// A connection's `nodes`; a missing list is told apart from an empty one.
struct GitHubNodes<Node: Decodable & Sendable>: Decodable, Sendable {
    var rows: [Node?]

    init(from decoder: Decoder) throws {
        rows = try decoder.singleValueContainer().decode([Node?].self)
    }
}

struct GitHubPageInfo: Decodable, Sendable {
    var hasNextPage: Bool
}

struct GitHubConnection<Node: Decodable & Sendable>: Decodable, Sendable {
    var nodes: GitHubNodes<Node>?
    var totalCount: Int?
    var pageInfo: GitHubPageInfo?
}

struct GitHubPullRequestRepository: Decodable, Sendable {
    var nameWithOwner: String
    var pullRequests: GitHubConnection<GitHubPullRequestNode>?
    var pullRequest: GitHubPullRequestNode?
}

struct GitHubPullRequestNode: Decodable, Sendable {
    var number: Int
    var title: String
    var state: String?
    @DecodedDefault<DefaultFalse> var isDraft: Bool
    var author: GitHubActor?
    var headRefName: String?
    var headRefOid: String?
    var baseRefName: String?
    var reviewDecision: String?
    var mergeable: String?
    var url: String?
    var updatedAt: String?
    var commits: GitHubConnection<GitHubCommitNode>?
    var mergeCommit: GitHubCommit?
    var createdAt: String?
    var mergedAt: String?
    var mergedBy: GitHubActor?
    var latestReviews: GitHubConnection<GitHubReviewNode>?
    var reviewRequests: GitHubConnection<GitHubReviewRequestNode>?

    /// The newest commit GitHub reports for the pull request.
    var tip: GitHubCommit? { commits?.nodes?.rows.compactMap { $0 }.last?.commit }

    /// Checks of the current head only; a rollup of an older head is never reused.
    var currentRollup: GitHubRollup? {
        guard let head = ProviderValidation.nonempty(headRefOid), let tip, tip.oid == head else { return nil }
        return tip.statusCheckRollup
    }
}

struct GitHubCommitNode: Decodable, Sendable { var commit: GitHubCommit? }

struct GitHubCommit: Decodable, Sendable {
    var oid: String?
    var statusCheckRollup: GitHubRollup?
}

struct GitHubRollup: Decodable, Sendable {
    var state: String?
    var contexts: GitHubCheckContexts?
}

struct GitHubCheckContexts: Decodable, Sendable {
    var nodes: GitHubNodes<GitHubCheckNode>?
    var checkRunCount: Int?
    var statusContextCount: Int?
    var pageInfo: GitHubPageInfo?
}

struct GitHubCheckNode: Decodable, Sendable {
    struct Suite: Decodable, Sendable { var workflowRun: Run? }
    struct Run: Decodable, Sendable { var workflow: Workflow? }
    struct Workflow: Decodable, Sendable { var name: String? }

    var typename: String?
    var id: String?
    var name: String?
    var context: String?
    var status: String?
    var state: String?
    var conclusion: String?
    var detailsUrl: String?
    var targetUrl: String?
    var checkSuite: Suite?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id, name, context, status, state, conclusion, detailsUrl, targetUrl, checkSuite
    }
}

struct GitHubReviewNode: Decodable, Sendable {
    var id: String
    var author: GitHubActor?
    var state: String?
}

struct GitHubReviewRequestNode: Decodable, Sendable {
    struct Reviewer: Decodable, Sendable {
        var typename: String?
        var id: String?
        var login: String?
        var name: String?
        var slug: String?
        var organization: GitHubActor?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, login, name, slug, organization
        }
    }

    var requestedReviewer: Reviewer?
}
