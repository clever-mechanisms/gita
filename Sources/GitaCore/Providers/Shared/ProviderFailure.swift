import Foundation

/// A failed provider read: a status token and a fixed, bounded diagnostic. Raw CLI output never reaches it.
struct ProviderFailure: Error, Sendable, Hashable {
    var status: ProviderStatus
    var diagnostic: String
    /// Set when GitHub hid the repository from the account that asked, so another account is worth trying.
    var access: GitHubAccessProblem?

    static let cancelled = Self(
        status: .cancelled, diagnostic: String(localized: "Provider request was cancelled."))

    static let invalidIdentity = Self(
        status: .unavailable,
        diagnostic: String(localized: "The provider item has an invalid identity. Refresh its list and try again."))

    static let notLinked = Self(
        status: .notLinked, diagnostic: String(localized: "No linked Vercel checkout is available for this repository.")
    )

    static func github(_ problem: GitHubAccessProblem) -> Self {
        switch problem {
        case .notVisible:
            Self(
                status: .accessDenied,
                diagnostic: String(localized: "The GitHub account in use can’t see this repository."),
                access: problem)
        case .ssoRequired:
            Self(
                status: .accessDenied,
                diagnostic: String(
                    localized: """
                        The organization requires single sign-on for the GitHub account in use. Authorize it on \
                        github.com, then refresh.
                        """),
                access: problem)
        }
    }

    /// A `gita-gh` command whose account is no longer signed in to `gh`.
    static func signedOut(_ account: GitHubAccountID) -> Self {
        if let profile = account.profile {
            let path = profile.displayPath
            return Self(
                status: .signInRequired,
                diagnostic: String(
                    localized: """
                        The GitHub account \(account.login.value) is not signed in (\(path)). Run \
                        GH_CONFIG_DIR=\(path) gh auth login in Terminal, then refresh.
                        """))
        }
        return Self(
            status: .signInRequired,
            diagnostic: String(
                localized: """
                    The GitHub account \(account.login.value) is not signed in. Run gh auth login in Terminal, then \
                    refresh.
                    """))
    }

    static func notInstalled(_ tool: ProviderTool) -> Self {
        Self(
            status: .notInstalled,
            diagnostic: String(localized: "Install the \(tool.displayName) CLI to connect this provider."))
    }

    static func timedOut(_ tool: ProviderTool) -> Self {
        Self(
            status: .timedOut, diagnostic: String(localized: "\(tool.displayName) did not respond within 20 seconds."))
    }

    static func tooLarge(_ tool: ProviderTool) -> Self {
        Self(
            status: .responseTooLarge, diagnostic: String(localized: "\(tool.displayName) exceeded the response limit.")
        )
    }

    static func incomplete(_ tool: ProviderTool) -> Self {
        Self(
            status: .unavailable, diagnostic: String(localized: "\(tool.displayName) could not complete the request."))
    }

    static func unsupportedResponse(_ tool: ProviderTool) -> Self {
        Self(
            status: .unavailable, diagnostic: String(localized: "\(tool.displayName) returned an unsupported response.")
        )
    }

    static func unverified(_ tool: ProviderTool) -> Self {
        Self(
            status: .unavailable,
            diagnostic: String(localized: "\(tool.displayName) returned details that could not be verified."))
    }
}
