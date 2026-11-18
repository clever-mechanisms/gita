import Foundation
import GitaCore

/// The accounts `gh` is signed in to on github.com, read when a GitHub page opens and again on its Refresh; never on a
/// timer. Logins only.
enum GitHubAccountsRead {
    case unread
    case reading(UUID, Task<Void, Never>)
    case read([GitHubAccount])
}

/// The GitHub page's account picker: Automatic, then each signed-in login. Shown only when there are several.
struct GitHubAccountPicker: Equatable {
    var logins: [GitHubLogin]
    var choice: GitHubAccountChoice?
    /// The account the latest list read ran as.
    var viewer: String?

    /// "Automatic (login)" names the account Automatic read with; after a choice it no longer knows.
    var titles: [String] {
        let isChosen = if case .chosen = choice { true } else { false }
        let named = isChosen ? nil : viewer.map { String(localized: "Automatic (\($0))") }
        return [named ?? String(localized: "Automatic")] + logins.map(\.value)
    }

    var selectedIndex: Int {
        guard case .chosen(let login) = choice, let index = logins.firstIndex(of: login) else { return 0 }
        return index + 1
    }

    /// The login at a menu index; nil for Automatic.
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

    /// The picker for this repository; nil until the accounts are read, for a non-GitHub remote, or with one account.
    var githubAccountPicker: GitHubAccountPicker? {
        guard case .read(let accounts) = providers.githubAccounts, let sourceID = snapshot?.github?.sourceID else {
            return nil
        }
        let logins = accounts.filter(\.isSignedIn).map(\.login).sorted()
        guard logins.count > 1 else { return nil }
        return GitHubAccountPicker(
            logins: logins, choice: GitHubAccountStore(defaults: defaults).choice(for: sourceID),
            viewer: providers.viewerLogin)
    }

    /// The user picked an account for this repository (nil: Automatic); the lists are read again as it.
    func chooseGitHubAccount(_ login: GitHubLogin?) {
        guard let sourceID = snapshot?.github?.sourceID else { return }
        GitHubAccountStore(defaults: defaults).choose(login, sourceID: sourceID)
        providers.details.removeAll()
        // A read still running as the previous account must not land, nor keep this one from starting.
        providers.full.cancel()
        refreshProviders()
    }
}
