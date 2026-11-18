import Foundation

/// One `gh` account on github.com, as `gh auth status --json hosts` lists it. Never carries a token.
public struct GitHubAccount: Sendable, Equatable {
    public var login: GitHubLogin
    /// The account `gh` uses when no account is named.
    public var isActive: Bool
    /// `gh` holds a working session for it.
    public var isSignedIn: Bool
}

/// Which `gh` account reads a repository: the account the user chose for it, or the one Gita found that could see
/// it. Stored per repository (`ProviderReport.sourceID`); logins only.
public enum GitHubAccountChoice: Sendable, Hashable {
    /// Found by Gita: a signed-in account that could see the repository when the active one could not.
    case automatic(GitHubLogin)
    /// Picked by the user for this repository; never replaced by Gita.
    case chosen(GitHubLogin)

    public var login: GitHubLogin {
        switch self {
        case .automatic(let login), .chosen(let login): login
        }
    }
}

/// What a GitHub read learned about the account to remember for the repository.
public enum GitHubAccountUpdate: Sendable, Hashable {
    /// Keep what is stored.
    case keep
    /// Remember this account for the repository.
    case store(GitHubLogin)
    /// The stored automatic account no longer works: forget it.
    case forget
}

/// The accounts `gh` knows for github.com, read only when a repository was not visible or Settings asks: no polling.
public enum GitHubAccounts {
    /// `--no-refresh`: listing never renews a token; the JSON has no token field without `--show-token`.
    public static let arguments = ["auth", "status", "--json", "hosts", "--hostname", "github.com", "--no-refresh"]

    private struct Status: Decodable {
        struct Entry: Decodable {
            var login: String?
            @DecodedDefault<DefaultFalse> var active: Bool
            var state: String?
        }
        var hosts: [String: [Entry]]
    }

    /// The accounts in `gh auth status` output; throws when it is not that output. `gh` exits 1 when one account's
    /// session is broken and still prints the list.
    public static func parse(_ result: CommandResult) throws -> [GitHubAccount] {
        guard result.exitCode == 0 || result.exitCode == 1 else { throw ProviderResponseError.shape }
        let status = try JSONDecoder().decode(Status.self, from: result.stdout)
        return (status.hosts["github.com"] ?? []).compactMap { entry in
            guard let login = entry.login.flatMap(GitHubLogin.init) else { return nil }
            return GitHubAccount(login: login, isActive: entry.active, isSignedIn: entry.state == "success")
        }
    }

    /// Throws when `gh` is missing, fails or prints something else: then nothing is decided from the list.
    static func list(_ executor: ProviderCommandExecutor, root: URL) async throws -> [GitHubAccount] {
        try parse(try await executor.run(.gh, arguments, in: root).get())
    }

    /// The signed-in accounts worth trying after `tried` failed, in order: the remote's login hint, the active
    /// account, then the others by login.
    static func candidates(
        _ accounts: [GitHubAccount], excluding tried: Set<GitHubLogin>, hint: GitHubLogin?, active: GitHubLogin?
    ) -> [GitHubLogin] {
        let signedIn = Set(accounts.filter(\.isSignedIn).map(\.login)).subtracting(tried)
        let first = [hint, active].compactMap { $0 }.filter(signedIn.contains)
        var ordered: [GitHubLogin] = []
        for login in first + signedIn.sorted() where !ordered.contains(login) { ordered.append(login) }
        return ordered
    }

    /// How a write runs as `viewer`: named when `gh` has several accounts, the active one when `viewer` is the only
    /// account, nil when the only account is someone else. No listed account (an unreadable list, or a `GH_TOKEN`
    /// session that lists none) keeps `gh`'s own choice.
    static func writer(_ viewer: GitHubLogin, among accounts: [GitHubAccount]) -> GitHubAccountUse? {
        guard !accounts.isEmpty else { return .active }
        if accounts.count > 1 { return .named(viewer) }
        return viewer.matches(accounts[0].login.value) ? .active : nil
    }
}
