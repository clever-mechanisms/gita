import Foundation

/// The sentences that explain which GitHub account could not read a repository.
enum GitHubAccountText {
    /// The account the user chose for this repository failed; Gita does not replace it.
    static func chosenFailed(_ account: GitHubAccountID, failure: ProviderFailure?) -> String {
        if failure?.access == nil {
            if let profile = account.profile {
                let path = profile.displayPath
                return String(
                    localized: """
                        \(account.login.value), the account chosen for this repository, is not signed in to gh \
                        (\(path)). Sign in with GH_CONFIG_DIR=\(path) gh auth login, or choose another account on the \
                        GitHub page.
                        """)
            }
            return String(
                localized: """
                    \(account.login.value), the account chosen for this repository, is not signed in to gh. Sign in \
                    with gh auth login, or choose another account on the GitHub page.
                    """)
        }
        return String(
            localized: """
                \(account.login.value), the account chosen for this repository, can’t see it. Choose another account \
                on the GitHub page.
                """)
    }

    /// No signed-in account could see the repository; `needsSSO` names one the organization's single sign-on blocks.
    static func noAccess(
        _ logins: [GitHubLogin], repository: GitHubRepository, needsSSO: GitHubLogin?
    ) -> String {
        let names = logins.map(\.value).joined(separator: ", ")
        let base: String
        switch logins.count {
        case 0:
            base = String(localized: "No signed-in GitHub account can see \(repository.nameWithOwner).")
        case 1:
            base = String(localized: "The GitHub account \(names) can’t see \(repository.nameWithOwner).")
        default:
            base = String(localized: "None of your GitHub accounts (\(names)) can see \(repository.nameWithOwner).")
        }
        guard let needsSSO else { return base }
        return base + " "
            + String(
                localized: """
                    \(repository.owner) requires single sign-on for \(needsSSO.value): authorize it on github.com, \
                    then refresh.
                    """)
    }
}
