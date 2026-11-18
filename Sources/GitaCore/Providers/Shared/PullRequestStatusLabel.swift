import Foundation

/// An open pull request's list label: its review decision, then its head checks. Both are read once from the
/// provider's word and localized only by their `localizedTitle`.
public struct PullRequestStatusLabel: Sendable, Hashable {
    /// A review decision, or one review's state.
    public enum Review: Sendable, CaseIterable {
        case open, approved, changesRequested, reviewRequired, commented, dismissed, pending, unknown

        public var localizedTitle: String {
            switch self {
            case .open: ProviderText.openPullRequest
            case .approved: String(localized: "Approved")
            case .changesRequested: String(localized: "Changes requested")
            case .reviewRequired: String(localized: "Review required")
            case .commented: String(localized: "Commented")
            case .dismissed: String(localized: "Dismissed")
            case .pending: VercelSignals.CIStatus.pending.localizedTitle
            case .unknown: VercelSignals.CIStatus.unknown.localizedTitle
            }
        }
    }

    /// The head commit's check rollup; `unavailable` when the provider reported none or a state it never defined.
    public enum Checks: Sendable, CaseIterable {
        case failing, pending, unavailable, passed

        public var state: SignalState {
            switch self {
            case .failing: .failure
            case .pending: .pending
            case .unavailable: .neutral
            case .passed: .success
            }
        }

        /// The rollup on its own ("Passed"), as in a pull request's head-checks tooltip.
        public var localizedTitle: String {
            switch self {
            case .failing: String(localized: "Failing")
            case .pending: VercelSignals.CIStatus.pending.localizedTitle
            case .unavailable: VercelSignals.CIStatus.unknown.localizedTitle
            case .passed: VercelSignals.CIStatus.passed.localizedTitle
            }
        }
    }

    public var review: Review
    /// nil: the label names the review only (changes requested while no check fails).
    public var checks: Checks?

    public init(review: Review, checks: Checks?) {
        self.review = review
        self.checks = checks
    }

    /// "<review> · <checks>", or the review alone.
    public var localizedTitle: String {
        let review = review.localizedTitle
        switch checks {
        case nil: return review
        case .failing: return String(localized: "\(review) · Checks failing")
        case .pending: return String(localized: "\(review) · Checks pending")
        case .unavailable: return String(localized: "\(review) · Checks unavailable")
        case .passed: return String(localized: "\(review) · Checks passed")
        }
    }
}
