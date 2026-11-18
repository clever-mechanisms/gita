import Foundation

/// Where a pull request is in its life, as GitHub reports it (`state`). Raw values are GitHub's tokens.
public enum PullRequestLifecycle: String, Sendable, Hashable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    /// Missing, or a state this version does not know.
    case unknown = "UNKNOWN"

    init(gitHub state: String?) { self = state.flatMap(Self.init(rawValue:)) ?? .unknown }

    public var localizedTitle: String {
        switch self {
        case .open: ProviderText.openPullRequest
        case .closed: String(localized: "Closed")
        case .merged: String(localized: "Merged")
        case .unknown: String(localized: "Unknown")
        }
    }
}
