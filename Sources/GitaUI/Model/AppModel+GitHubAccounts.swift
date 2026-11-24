import Foundation
import GitaCore

/// The accounts `gh` is signed in to on github.com, read when a GitHub page opens and again on its Refresh; never on a
/// timer. Logins only.
enum GitHubAccountsRead {
    case unread
    case reading(UUID, Task<Void, Never>)
    case read([GitHubAccount])
}

/// The GitHub page's account picker: Automatic, then each signed-in login (even when 0 or 1 account is signed in).
struct GitHubAccountPicker: Equatable {
    var logins: [GitHubLogin]
    var choice: GitHubAccountChoice?
    /// The account the latest list read ran as.
    var viewer: String?

    private var missingChosenLogin: GitHubLogin? {
        guard case .chosen(let login) = choice, !logins.contains(login) else { return nil }
        return login
    }

    /// "Automatic (login)" names the account Automatic read with (or the sole signed-in account); after a choice it
    /// no longer knows.
    var titles: [String] {
        if logins.isEmpty {
            if let missing = missingChosenLogin {
                return [String(localized: "Automatic"), String(localized: "\(missing.value) (signed out)")]
            }
            return [String(localized: "No signed-in account")]
        }
        let isChosen = if case .chosen = choice { true } else { false }
        let soleLogin = logins.count == 1 ? logins[0].value : nil
        let automaticName = isChosen ? nil : (viewer ?? choice?.login.value ?? soleLogin)
        let named = automaticName.map { String(localized: "Automatic (\($0))") }
        var result = [named ?? String(localized: "Automatic")] + logins.map(\.value)
        if let missing = missingChosenLogin {
            result.append(String(localized: "\(missing.value) (signed out)"))
        }
        return result
    }

    var selectedIndex: Int {
        guard case .chosen(let login) = choice else { return 0 }
        if logins.isEmpty { return 1 }
        if let index = logins.firstIndex(of: login) { return index + 1 }
        return logins.count + 1
    }

    /// The login at a menu index; nil for Automatic or when no account is signed in.
    func login(at index: Int) -> GitHubLogin? {
        logins.indices.contains(index - 1) ? logins[index - 1] : nil
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
        let logins = accounts.filter(\.isSignedIn).map(\.login).sorted()
        return GitHubAccountPicker(
            logins: logins, choice: GitHubAccountStore(defaults: defaults).choice(for: sourceID),
            viewer: providers.viewerLogin)
    }

    /// The user picked an account for this repository (nil: Automatic); the lists are read again as it.
    func chooseGitHubAccount(_ login: GitHubLogin?) {
        guard let sourceID = snapshot?.github?.sourceID else { return }
        GitHubAccountStore(defaults: defaults).choose(login, sourceID: sourceID)
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
