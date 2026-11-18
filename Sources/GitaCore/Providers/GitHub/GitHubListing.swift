import Foundation

/// One GitHub list read: the report, the signed-in `gh` account the same request named (`viewer { login }`), so
/// "review requested from me" and "someone else opened or merged" need no extra `gh api user` call, and what to
/// remember about the account for this repository. Logins are never credentials.
public struct GitHubListing: Sendable {
    public var report: ProviderReport
    public var viewerLogin: String?
    public var account: GitHubAccountUpdate = .keep
}
