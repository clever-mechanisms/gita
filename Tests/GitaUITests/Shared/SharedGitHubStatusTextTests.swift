import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Every GitHub check-rollup, review, review-decision and mergeability spelling, from the GitHub response through
/// the parsers to the text shown. Written against the labels shown before these statuses were typed.
@MainActor
@Suite struct SharedGitHubStatusTextTests {
    typealias Facts = ProviderDetailFacts

    static let rollups: [(spelling: String, label: String, state: SignalState, pending: Bool)] = [
        ("SUCCESS", "Passed", .success, false),
        ("FAILURE", "Failing", .failure, false),
        ("ERROR", "Failing", .failure, false),
        ("PENDING", "Pending", .pending, true),
        ("EXPECTED", "Pending", .pending, true),
        ("UNKNOWN", "Unknown", .neutral, false),
    ]

    static let reviews: [(spelling: String, label: String)] = [
        ("APPROVED", "Approved"),
        ("CHANGES_REQUESTED", "Changes requested"),
        ("COMMENTED", "Commented"),
        ("DISMISSED", "Dismissed"),
        ("PENDING", "Pending"),
        ("REVIEW_REQUIRED", "Review required"),
        ("FUTURE_STATE", "Unknown"),
        ("", "Unknown"),
    ]

    static let decisions: [(spelling: String?, lines: [String])] = [
        ("APPROVED", ["Approved"]),
        ("CHANGES_REQUESTED", ["Changes requested"]),
        ("REVIEW_REQUIRED", ["Review required"]),
        ("FUTURE_STATE", ["Unknown"]),
        ("", []),
        (nil, []),
    ]

    static let mergeability: [(spelling: String?, label: String?)] = [
        ("MERGEABLE", "Mergeable"),
        ("CONFLICTING", "Conflicts"),
        ("UNKNOWN", nil),
        (nil, nil),
    ]

    @Test func checkRollupSpellingsShowTheirLabel() throws {
        for row in Self.rollups {
            let item = try #require(try Self.summaryItem(rollup: row.spelling), "\(row.spelling)")
            let chip = try #require(HistoryChips.checks(runs: [], pullRequest: item), "\(row.spelling)")
            #expect(chip.tooltip == "PR #42 head checks · \(row.label)", "\(row.spelling)")
            #expect(chip.color == Theme.color(for: row.state), "\(row.spelling)")
            #expect(ProviderRefreshPolicy.hasPendingSignals([item]) == row.pending, "\(row.spelling)")
        }
        let none = try #require(try Self.summaryItem(rollup: nil))
        #expect(HistoryChips.checks(runs: [], pullRequest: none) == nil)
        #expect(!ProviderRefreshPolicy.hasPendingSignals([none]))
    }

    @Test func reviewSpellingsShowTheirLabel() throws {
        for row in Self.reviews {
            var pr = Self.pullRequest()
            pr["latestReviews"] = Self.connection([["id": "r1", "state": row.spelling, "author": ["login": "ada"]]])
            #expect(Facts.reviewLines(try Self.detail(pr)) == ["\(row.label) · ada"], "\(row.spelling)")
        }
    }

    @Test func reviewDecisionSpellingsShowTheirLabel() throws {
        for row in Self.decisions {
            var pr = Self.pullRequest()
            pr["reviewDecision"] = row.spelling ?? NSNull()
            #expect(Facts.reviewLines(try Self.detail(pr)) == row.lines, "\(row.spelling ?? "nil")")
        }
    }

    @Test func mergeabilitySpellingsShowTheirLabel() throws {
        for row in Self.mergeability {
            var pr = Self.pullRequest()
            pr["mergeable"] = row.spelling ?? NSNull()
            #expect(Facts.merge(try Self.detail(pr)) == row.label, "\(row.spelling ?? "nil")")
        }
    }

    // MARK: GitHub responses

    private static func connection(_ nodes: [Any]) -> [String: Any] {
        ["nodes": nodes, "totalCount": nodes.count, "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
    }

    private static func pullRequest(rollup: String? = nil) -> [String: Any] {
        let contexts: [String: Any] = [
            "nodes": [], "checkRunCount": 0, "statusContextCount": 0,
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ]
        let statusCheckRollup: Any = rollup.map { ["state": $0, "contexts": contexts] as [String: Any] } ?? NSNull()
        return [
            "number": 42, "title": "Ship", "state": "OPEN", "isDraft": false, "author": ["login": "author"],
            "headRefOid": "head", "headRefName": "feature", "baseRefName": "main", "reviewDecision": NSNull(),
            "mergeable": "MERGEABLE", "url": "https://github.com/org/repo/pull/42",
            "commits": ["nodes": [["commit": ["oid": "head", "statusCheckRollup": statusCheckRollup]]]],
            "latestReviews": connection([]), "reviewRequests": connection([]),
        ]
    }

    private static func envelope(_ repository: [String: Any]) throws -> GitHubPullRequestDetailParser.Envelope {
        let data = try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]])
        return try JSONDecoder().decode(GitHubPullRequestDetailParser.Envelope.self, from: data)
    }

    private static let repository = GitHubRepository(nameWithOwner: "org/repo")

    private static func summaryItem(rollup: String?) throws -> ProviderItem? {
        let repository = try #require(repository)
        let envelope = try envelope([
            "nameWithOwner": "org/repo", "pullRequests": connection([pullRequest(rollup: rollup)]),
        ])
        return try GitHubPullRequestSummaryParser.items(envelope, repository: repository).value.first
    }

    private static func detail(_ pr: [String: Any]) throws -> PullRequestDetail {
        let repository = try #require(repository)
        let envelope = try envelope(["nameWithOwner": "org/repo", "pullRequest": pr])
        return try GitHubPullRequestDetailParser.detail(envelope, repository: repository, number: 42).value
    }
}
