import Foundation

/// GitHub's pull request vocabulary (lifecycle, review decision, check rollup, mergeability), read once into states
/// and typed values. Lifecycle tokens are localized at the presentation boundary by `ProviderText`.
enum GitHubPullRequestState {
    /// The list's state and label. A merged, closed, unknown or draft pull request is labelled by its status token
    /// alone; an open one by its review and checks: failing checks first, then requested changes, pending checks.
    static func summary(
        _ row: GitHubPullRequestNode, checks: PullRequestStatusLabel.Checks?
    ) -> (state: SignalState, token: String, label: PullRequestStatusLabel?) {
        switch PullRequestLifecycle(gitHub: row.state) {
        case .merged: return (.success, "Merged", nil)
        case .closed: return (.neutral, "Closed", nil)
        case .open: break
        case .unknown: return (.neutral, "Unknown", nil)
        }
        if row.isDraft { return (.neutral, "Draft", nil) }
        let (state, label) = openSummary(review: review(row.reviewDecision) ?? .open, checks: checks ?? .unavailable)
        return (state, "", label)
    }

    private static func openSummary(
        review: PullRequestStatusLabel.Review, checks: PullRequestStatusLabel.Checks
    ) -> (SignalState, PullRequestStatusLabel) {
        switch (checks, review) {
        case (.failing, _): (.failure, .init(review: review, checks: .failing))
        case (_, .changesRequested): (.failure, .init(review: review, checks: nil))
        case (.pending, _): (.pending, .init(review: review, checks: .pending))
        case (.unavailable, _): (.neutral, .init(review: review, checks: .unavailable))
        case (.passed, _): (review == .approved ? .success : .pending, .init(review: review, checks: .passed))
        }
    }

    private static let reviews: [String: PullRequestStatusLabel.Review] = [
        "APPROVED": .approved, "CHANGES_REQUESTED": .changesRequested, "REVIEW_REQUIRED": .reviewRequired,
        "COMMENTED": .commented, "DISMISSED": .dismissed, "PENDING": .pending,
    ]

    /// A review decision or review state; nil when GitHub reported none.
    static func review(_ value: String?) -> PullRequestStatusLabel.Review? {
        guard let value, !value.isEmpty else { return nil }
        return reviews[value] ?? .unknown
    }

    /// The head commit's check rollup state; nil when GitHub reported no rollup.
    static func checks(_ value: String?) -> PullRequestStatusLabel.Checks? {
        switch value {
        case nil: nil
        case "SUCCESS": .passed
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: .unavailable
        }
    }

    static func mergeability(_ value: String?) -> PullRequestMergeability? {
        switch value {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: nil
        }
    }
}
