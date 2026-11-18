import Foundation

/// Presentation for the finite status vocabulary authored by the adapters as item status tokens.
/// Raw model values remain stable for coverage, caching, notifications and icons.
/// Do not pass provider names, user content or arbitrary external diagnostics here.
public enum ProviderText {
    public static func status(_ raw: String) -> String {
        labels[raw] ?? raw
    }

    private static let labels: [String: String] = item.merging(orca) { first, _ in first }
        .merging(outcomes) { first, _ in first }
        .merging(pullRequest) { first, _ in first }

    /// Orca agent states, titled by `OrcaAgentState`.
    private static let orca = Dictionary(
        uniqueKeysWithValues: OrcaAgentState.allCases.map { ($0.rawValue, $0.localizedTitle) })

    /// Run outcomes, titled by `VercelSignals.CIStatus`; every provider's outcome tokens share them.
    private static let outcomes = Dictionary(
        uniqueKeysWithValues: VercelSignals.CIStatus.allCases.map { ($0.rawValue, $0.localizedTitle) })

    /// Item states; connection statuses are `ProviderStatus.localizedTitle`.
    private static let item: [String: String] = [
        "Connected": ProviderStatus.connected.localizedTitle,
        "Failing": String(localized: "Failing"),
        "Stale": String(localized: "Stale"),
        "Neutral": String(localized: "Neutral"),
        "Completed": String(localized: "Completed"),
        "Reported": String(localized: "Reported"),
        "Status unknown": String(localized: "Status unknown"),
        "Ready": String(localized: "Ready"),
        "Blocked": String(localized: "Blocked"),
    ]

    static let openPullRequest = String(
        localized: "provider.status.open", defaultValue: "Open",
        comment: "State of an open pull request, not the Open action.")

    /// Pull request items without a review-and-checks label (merged, closed, draft), and reviewer kinds.
    private static let pullRequest: [String: String] = [
        "Open": openPullRequest, "Closed": PullRequestLifecycle.closed.localizedTitle,
        "Merged": PullRequestLifecycle.merged.localizedTitle,
        "Draft": String(localized: "Draft"),
    ]
}

extension ProviderItem {
    /// The item's status text: an open pull request's review and checks, else its status token.
    public var localizedDetail: String { pullRequest?.status?.localizedTitle ?? ProviderText.status(detail) }
}

extension ProviderReport {
    public var localizedStatus: String { status.localizedTitle }
}

extension ProviderDetailReport {
    public var localizedStatus: String { status.localizedTitle }
}
