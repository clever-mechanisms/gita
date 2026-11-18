import Foundation
import Testing

@testable import GitaCore

/// Open pull request labels are built from their typed review and checks. The expected texts are the labels the
/// former "<review> · <checks>" string path produced for the same input, recorded before it was removed.
@Suite struct PullRequestStatusLabelTests: ProviderDetailFixtures {
    typealias Review = PullRequestStatusLabel.Review

    static let reviews: [(Review, String)] = [
        (.open, "Open"), (.approved, "Approved"), (.changesRequested, "Changes requested"),
        (.reviewRequired, "Review required"), (.commented, "Commented"), (.dismissed, "Dismissed"),
        (.pending, "Pending"), (.unknown, "Unknown"),
    ]
    static let checks: [(PullRequestStatusLabel.Checks?, String)] = [
        (nil, ""), (.failing, " · Checks failing"), (.pending, " · Checks pending"),
        (.unavailable, " · Checks unavailable"), (.passed, " · Checks passed"),
    ]

    @Test func everyReviewAndChecksCombinationKeepsItsLabel() {
        #expect(Self.reviews.map(\.0) == Review.allCases)
        #expect(Self.checks.compactMap(\.0) == PullRequestStatusLabel.Checks.allCases)
        for (review, reviewText) in Self.reviews {
            for (checks, checksText) in Self.checks {
                let label = PullRequestStatusLabel(review: review, checks: checks)
                #expect(label.localizedTitle == reviewText + checksText, "\(review) \(String(describing: checks))")
            }
        }
    }

    /// (reviewDecision, check rollup, state, label) of an open, ready pull request.
    static let recorded: [(String?, String?, SignalState, String)] = [
        (nil, nil, .neutral, "Open · Checks unavailable"),
        (nil, "FAILURE", .failure, "Open · Checks failing"),
        (nil, "ERROR", .failure, "Open · Checks failing"),
        (nil, "PENDING", .pending, "Open · Checks pending"),
        (nil, "EXPECTED", .pending, "Open · Checks pending"),
        (nil, "SUCCESS", .pending, "Open · Checks passed"),
        (nil, "NEW", .neutral, "Open · Checks unavailable"),
        ("", nil, .neutral, "Open · Checks unavailable"),
        ("", "FAILURE", .failure, "Open · Checks failing"),
        ("", "ERROR", .failure, "Open · Checks failing"),
        ("", "PENDING", .pending, "Open · Checks pending"),
        ("", "EXPECTED", .pending, "Open · Checks pending"),
        ("", "SUCCESS", .pending, "Open · Checks passed"),
        ("", "NEW", .neutral, "Open · Checks unavailable"),
        ("APPROVED", nil, .neutral, "Approved · Checks unavailable"),
        ("APPROVED", "FAILURE", .failure, "Approved · Checks failing"),
        ("APPROVED", "ERROR", .failure, "Approved · Checks failing"),
        ("APPROVED", "PENDING", .pending, "Approved · Checks pending"),
        ("APPROVED", "EXPECTED", .pending, "Approved · Checks pending"),
        ("APPROVED", "SUCCESS", .success, "Approved · Checks passed"),
        ("APPROVED", "NEW", .neutral, "Approved · Checks unavailable"),
        ("CHANGES_REQUESTED", nil, .failure, "Changes requested"),
        ("CHANGES_REQUESTED", "FAILURE", .failure, "Changes requested · Checks failing"),
        ("CHANGES_REQUESTED", "ERROR", .failure, "Changes requested · Checks failing"),
        ("CHANGES_REQUESTED", "PENDING", .failure, "Changes requested"),
        ("CHANGES_REQUESTED", "EXPECTED", .failure, "Changes requested"),
        ("CHANGES_REQUESTED", "SUCCESS", .failure, "Changes requested"),
        ("CHANGES_REQUESTED", "NEW", .failure, "Changes requested"),
        ("REVIEW_REQUIRED", nil, .neutral, "Review required · Checks unavailable"),
        ("REVIEW_REQUIRED", "FAILURE", .failure, "Review required · Checks failing"),
        ("REVIEW_REQUIRED", "ERROR", .failure, "Review required · Checks failing"),
        ("REVIEW_REQUIRED", "PENDING", .pending, "Review required · Checks pending"),
        ("REVIEW_REQUIRED", "EXPECTED", .pending, "Review required · Checks pending"),
        ("REVIEW_REQUIRED", "SUCCESS", .pending, "Review required · Checks passed"),
        ("REVIEW_REQUIRED", "NEW", .neutral, "Review required · Checks unavailable"),
        ("COMMENTED", nil, .neutral, "Commented · Checks unavailable"),
        ("COMMENTED", "FAILURE", .failure, "Commented · Checks failing"),
        ("COMMENTED", "ERROR", .failure, "Commented · Checks failing"),
        ("COMMENTED", "PENDING", .pending, "Commented · Checks pending"),
        ("COMMENTED", "EXPECTED", .pending, "Commented · Checks pending"),
        ("COMMENTED", "SUCCESS", .pending, "Commented · Checks passed"),
        ("COMMENTED", "NEW", .neutral, "Commented · Checks unavailable"),
        ("DISMISSED", nil, .neutral, "Dismissed · Checks unavailable"),
        ("DISMISSED", "FAILURE", .failure, "Dismissed · Checks failing"),
        ("DISMISSED", "ERROR", .failure, "Dismissed · Checks failing"),
        ("DISMISSED", "PENDING", .pending, "Dismissed · Checks pending"),
        ("DISMISSED", "EXPECTED", .pending, "Dismissed · Checks pending"),
        ("DISMISSED", "SUCCESS", .pending, "Dismissed · Checks passed"),
        ("DISMISSED", "NEW", .neutral, "Dismissed · Checks unavailable"),
        ("PENDING", nil, .neutral, "Pending · Checks unavailable"),
        ("PENDING", "FAILURE", .failure, "Pending · Checks failing"),
        ("PENDING", "ERROR", .failure, "Pending · Checks failing"),
        ("PENDING", "PENDING", .pending, "Pending · Checks pending"),
        ("PENDING", "EXPECTED", .pending, "Pending · Checks pending"),
        ("PENDING", "SUCCESS", .pending, "Pending · Checks passed"),
        ("PENDING", "NEW", .neutral, "Pending · Checks unavailable"),
        ("NEW", nil, .neutral, "Unknown · Checks unavailable"),
        ("NEW", "FAILURE", .failure, "Unknown · Checks failing"),
        ("NEW", "ERROR", .failure, "Unknown · Checks failing"),
        ("NEW", "PENDING", .pending, "Unknown · Checks pending"),
        ("NEW", "EXPECTED", .pending, "Unknown · Checks pending"),
        ("NEW", "SUCCESS", .pending, "Unknown · Checks passed"),
        ("NEW", "NEW", .neutral, "Unknown · Checks unavailable"),
    ]

    @Test func gitHubSummariesKeepTheirStateAndLabel() throws {
        for (decision, rollup, state, text) in Self.recorded {
            var row = pr(checksState: rollup)
            row["reviewDecision"] = decision ?? NSNull()
            let item = try #require(
                try ProviderDetailParsers.pullRequestSummaries(summary([row]), repository: "org/repo").value.first)
            let input = "\(decision ?? "nil") \(rollup ?? "nil")"
            #expect(item.state == state, "\(input)")
            #expect(item.localizedDetail == text, "\(input)")
            #expect(item.pullRequest?.status?.localizedTitle == text, "\(input)")
            #expect(item.detail.isEmpty, "\(input)")
        }
    }

    @Test func otherLifecyclesKeepTheirStatusToken() throws {
        for (state, draft, detail, text) in [
            ("MERGED", false, "Merged", "Merged"), ("CLOSED", false, "Closed", "Closed"),
            ("FUTURE_STATE", false, "Unknown", "Unknown"), ("OPEN", true, "Draft", "Draft"),
        ] {
            var row = pr()
            row["state"] = state
            row["isDraft"] = draft
            let item = try #require(
                try ProviderDetailParsers.pullRequestSummaries(summary([row]), repository: "org/repo").value.first)
            #expect(item.detail == detail)
            #expect(item.pullRequest?.status == nil)
            #expect(item.localizedDetail == text)
        }
    }

    @Test func compositeTextIsNoLongerParsed() {
        #expect(ProviderText.status("Approved · Checks failing") == "Approved · Checks failing")
        #expect(ProviderText.status("SUCCESS") == "SUCCESS")
        #expect(ProviderText.status("anything else") == "anything else")
    }
}
