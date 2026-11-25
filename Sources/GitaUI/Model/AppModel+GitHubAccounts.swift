import Foundation
import GitaCore

/// The accounts `gh` is signed in to on github.com, read when a GitHub page opens and again on its Refresh; never on a
/// timer. Logins and optional profile names only.
enum GitHubAccountsRead {
    case unread
    case reading(UUID, Task<Void, Never>)
    case read([GitHubAccount])
}

/// The GitHub page's account picker: Automatic, then each signed-in account (even when 0 or 1 account is signed in).
struct GitHubAccountPicker: Equatable {
    var accounts: [GitHubAccountID]
    var choice: GitHubAccountChoice?
    /// The account the latest list read ran as.
    var viewer: String?

    private var missingChosenAccount: GitHubAccountID? {
        guard case .chosen = choice, let chosen = choice?.accountID, !accounts.contains(chosen) else { return nil }
        return chosen
    }

    /// Plain login unless two or more accounts in `all` share the same login (case-insensitively), in which case the
    /// profile folder (or "default") disambiguates them.
    static func displayTitle(for account: GitHubAccountID, among all: [GitHubAccountID]) -> String {
        let key = account.login.value.lowercased()
        let duplicates = all.count { $0.login.value.lowercased() == key }
        guard duplicates > 1 else { return account.login.value }
        if let profile = account.profile {
            return "\(account.login.value) (\(profile.name))"
        }
        return String(localized: "\(account.login.value) (default)")
    }

    /// "Automatic (login)" names the account Automatic read with (or the sole signed-in account); after a choice it
    /// no longer knows.
    var titles: [String] {
        if accounts.isEmpty {
            if let missing = missingChosenAccount {
                return [String(localized: "Automatic"), String(localized: "\(missing.login.value) (signed out)")]
            }
            return [String(localized: "No signed-in account")]
        }
        let allForLabels = accounts + [missingChosenAccount].compactMap { $0 }
        let named = automaticLabel(among: allForLabels).map { String(localized: "Automatic (\($0))") }
        var result =
            [named ?? String(localized: "Automatic")]
            + accounts.map { Self.displayTitle(for: $0, among: allForLabels) }
        if let missing = missingChosenAccount {
            let label = Self.displayTitle(for: missing, among: allForLabels)
            result.append(String(localized: "\(label) (signed out)"))
        }
        return result
    }

    private func automaticLabel(among all: [GitHubAccountID]) -> String? {
        if case .chosen = choice { return nil }
        if let automatic = choice?.accountID {
            return Self.displayTitle(for: automatic, among: all)
        }
        if let viewer {
            if let match = accounts.first(where: { $0.login.value.lowercased() == viewer.lowercased() }) {
                return Self.displayTitle(for: match, among: all)
            }
            return viewer
        }
        return accounts.count == 1 ? Self.displayTitle(for: accounts[0], among: all) : nil
    }

    var selectedIndex: Int {
        guard case .chosen = choice, let chosen = choice?.accountID else { return 0 }
        if accounts.isEmpty { return 1 }
        if let index = accounts.firstIndex(of: chosen) { return index + 1 }
        return accounts.count + 1
    }

    /// The account at a menu index; nil for Automatic or when no account is signed in.
    func account(at index: Int) -> GitHubAccountID? {
        accounts.indices.contains(index - 1) ? accounts[index - 1] : nil
    }

    var toolTip: String {
        String(
            localized: """
                The gh account this repository is read as. Automatic uses the active account, or the first other \
                signed-in account that can see the repository.
                """)
    }
}

extension AppModel {
    /// Reads `gh`'s accounts once for the GitHub pages; `again` (their Refresh) reads them anew.
    func readGitHubAccounts(again: Bool = false) {
        switch providers.githubAccounts {
        case .reading: return
        case .read where !again: return
        case .read, .unread: break
        }
        guard let root else { return }
        let client = providerService
        let id = UUID()
        providers.githubAccounts = .reading(
            id,
            Task { [weak self] in
                let accounts = (try? await client.githubAccounts(root: root)) ?? []
                guard let self, case .reading(id, _) = self.providers.githubAccounts else { return }
                self.providers.githubAccounts = .read(accounts)
                self.emit(.providers)
            })
    }

    /// The picker for this repository; nil until the accounts are read or for a non-GitHub remote. Always shown on
    /// GitHub pages even when 0 or 1 account is signed in.
    var githubAccountPicker: GitHubAccountPicker? {
        guard case .read(let accounts) = providers.githubAccounts, let sourceID = snapshot?.github?.sourceID else {
            return nil
        }
        let signedIn = accounts.filter(\.isSignedIn).map(\.id).sorted()
        return GitHubAccountPicker(
            accounts: signedIn, choice: GitHubAccountStore(defaults: defaults).choice(for: sourceID),
            viewer: providers.viewerLogin)
    }

    /// The user picked an account for this repository (nil: Automatic); the lists are read again as it.
    func chooseGitHubAccount(_ account: GitHubAccountID?) {
        guard let sourceID = snapshot?.github?.sourceID else { return }
        GitHubAccountStore(defaults: defaults).choose(account, sourceID: sourceID)
        reloadGitHubAccount()
    }

    /// Called when Settings ▸ Integrations changed or reset an assignment for `sourceID`.
    func gitHubAccountAssignmentChanged(for sourceID: String) {
        guard snapshot?.github?.sourceID == sourceID else { return }
        reloadGitHubAccount()
    }

    private func reloadGitHubAccount() {
        providers.details.removeAll()
        // A read still running as the previous account must not land, nor keep this one from starting.
        providers.full.cancel()
        refreshProviders()
    }
}
