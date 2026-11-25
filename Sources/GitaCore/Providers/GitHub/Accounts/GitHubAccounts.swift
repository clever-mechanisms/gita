import Foundation

/// One `gh` account on github.com, as `gh auth status --json hosts` lists it. Never carries a token.
public struct GitHubAccount: Sendable, Equatable {
    public var login: GitHubLogin
    /// The account `gh` uses when no account is named (within its `profile`).
    public var isActive: Bool
    /// `gh` holds a working session for it.
    public var isSignedIn: Bool
    /// Sibling `GH_CONFIG_DIR` profile holding this account, or `nil` for `gh`'s default config directory.
    public var profile: GitHubConfigProfile?

    public var id: GitHubAccountID { GitHubAccountID(login, profile: profile) }

    public init(login: GitHubLogin, isActive: Bool, isSignedIn: Bool, profile: GitHubConfigProfile? = nil) {
        self.login = login
        self.isActive = isActive
        self.isSignedIn = isSignedIn
        self.profile = profile
    }

    /// Display sort order: signed-in first, default config before sibling profiles, active first, then by ID.
    public static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.isSignedIn != rhs.isSignedIn { return lhs.isSignedIn }
        let lhsDefault = lhs.profile == nil
        let rhsDefault = rhs.profile == nil
        if lhsDefault != rhsDefault { return lhsDefault }
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        return lhs.id < rhs.id
    }
}

/// Which `gh` account reads a repository: the account the user chose for it, or the one Gita found that could see
/// it. Stored per repository (`ProviderReport.sourceID`); logins and optional profile names only, never tokens.
public enum GitHubAccountChoice: Sendable, Hashable {
    /// Found by Gita: a signed-in account that could see the repository when the active one could not.
    case automatic(GitHubLogin, profile: GitHubConfigProfile? = nil)
    /// Picked by the user for this repository; never replaced by Gita.
    case chosen(GitHubLogin, profile: GitHubConfigProfile? = nil)

    public static func automatic(_ id: GitHubAccountID) -> Self {
        .automatic(id.login, profile: id.profile)
    }

    public static func chosen(_ id: GitHubAccountID) -> Self {
        .chosen(id.login, profile: id.profile)
    }

    public var login: GitHubLogin {
        switch self {
        case .automatic(let login, _), .chosen(let login, _): login
        }
    }

    public var profile: GitHubConfigProfile? {
        switch self {
        case .automatic(_, let profile), .chosen(_, let profile): profile
        }
    }

    public var accountID: GitHubAccountID { GitHubAccountID(login, profile: profile) }
}

/// What a GitHub read learned about the account to remember for the repository.
public enum GitHubAccountUpdate: Sendable, Hashable {
    /// Keep what is stored.
    case keep
    /// Remember this account for the repository.
    case store(GitHubLogin, profile: GitHubConfigProfile? = nil)
    /// The stored automatic account no longer works: forget it.
    case forget

    public static func store(_ id: GitHubAccountID) -> Self {
        .store(id.login, profile: id.profile)
    }
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
    public static func parse(_ result: CommandResult, profile: GitHubConfigProfile? = nil) throws -> [GitHubAccount] {
        guard result.exitCode == 0 || result.exitCode == 1 else { throw ProviderResponseError.shape }
        let status = try JSONDecoder().decode(Status.self, from: result.stdout)
        return (status.hosts["github.com"] ?? []).compactMap { entry in
            guard let login = entry.login.flatMap(GitHubLogin.init) else { return nil }
            return GitHubAccount(
                login: login, isActive: entry.active, isSignedIn: entry.state == "success", profile: profile)
        }
    }

    /// Lists accounts across `gh`'s default config directory and any discovered sibling `GH_CONFIG_DIR` folders.
    /// Throws `CommandError` when `gh` is missing or timed out, or another error when no directory answered.
    public static func list(
        configDirectories: GitHubConfigDirectories = .system, runner: any CommandRunning = CommandRunner()
    ) async throws -> [GitHubAccount] {
        do {
            return try await list(
                ProviderCommandExecutor(runner: runner), root: FileManager.default.homeDirectoryForCurrentUser,
                configDirectories: configDirectories)
        } catch let failure as ProviderFailure {
            switch failure.status {
            case .notInstalled: throw CommandError.executableNotFound(ProviderTool.gh.executable)
            case .timedOut: throw CommandError.timedOut
            default: throw failure
            }
        }
    }

    static func list(
        _ executor: ProviderCommandExecutor, root: URL, configDirectories: GitHubConfigDirectories = .none
    ) async throws -> [GitHubAccount] {
        try await list(
            executor, root: root, configDirectories: configDirectories, profiles: configDirectories.discover())
    }

    static func list(
        _ executor: ProviderCommandExecutor, root: URL, configDirectories: GitHubConfigDirectories,
        profiles: [GitHubConfigProfile]
    ) async throws -> [GitHubAccount] {
        if profiles.isEmpty {
            guard let command = ProviderCommand.ghAuthStatus(profile: nil, configDirectories: configDirectories) else {
                throw ProviderResponseError.shape
            }
            return try parse(try await executor.run(command, in: root).get())
        }
        let targets: [GitHubConfigProfile?] = [nil] + profiles
        let results = await probeAll(executor, root: root, targets: targets, configDirectories: configDirectories)
        return try merge(results)
    }

    private static func probeAll(
        _ executor: ProviderCommandExecutor, root: URL, targets: [GitHubConfigProfile?],
        configDirectories: GitHubConfigDirectories
    ) async -> [(index: Int, result: Result<[GitHubAccount], Error>)] {
        await withTaskGroup(of: (Int, Result<[GitHubAccount], Error>).self) { group in
            for (index, profile) in targets.enumerated() {
                group.addTask {
                    if Task.isCancelled { return (index, .failure(CancellationError())) }
                    guard
                        let command = ProviderCommand.ghAuthStatus(
                            profile: profile, configDirectories: configDirectories)
                    else {
                        return (index, .success([]))
                    }
                    let result: Result<[GitHubAccount], Error>
                    switch await executor.run(command, in: root) {
                    case .success(let output): result = Result { try parse(output, profile: profile) }
                    case .failure(let failure): result = .failure(failure)
                    }
                    return (index, result)
                }
            }
            var collected: [(Int, Result<[GitHubAccount], Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }
        }
    }

    private static func merge(
        _ results: [(index: Int, result: Result<[GitHubAccount], Error>)]
    ) throws -> [GitHubAccount] {
        var accounts: [GitHubAccount] = []
        var seen: Set<GitHubAccountID> = []
        var succeeded = 0
        var firstError: Error?
        for (_, item) in results {
            switch item {
            case .success(let listed):
                succeeded += 1
                for account in listed where seen.insert(account.id).inserted {
                    accounts.append(account)
                }
            case .failure(let error):
                if let failure = error as? ProviderFailure, failure.status == .notInstalled { throw failure }
                firstError = firstError ?? error
            }
        }
        if succeeded == 0, let firstError { throw firstError }
        return accounts
    }

    /// The signed-in accounts worth trying after `tried` failed, in order: the remote's HTTPS login hint, any
    /// profile matching the remote's SSH host alias, the default active account, then the rest by identity.
    static func candidates(
        _ accounts: [GitHubAccount], excluding tried: Set<GitHubAccountID>, hint: GitHubLogin?,
        sshAlias: String? = nil, active: GitHubAccountID?
    ) -> [GitHubAccountID] {
        let signedIn = accounts.filter(\.isSignedIn).map(\.id).filter { !tried.contains($0) }
        let hinted = signedIn.filter { id in hint.map { id.login.matches($0.value) } ?? false }
        let aliasMatched = signedIn.filter { $0.matchesSSHAlias(sshAlias) }
        let activeFirst = active.map { id in signedIn.contains(id) ? [id] : [] } ?? []
        var ordered: [GitHubAccountID] = []
        for id in hinted + aliasMatched + activeFirst + signedIn.sorted() where !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }

    /// How a write runs as `viewer` in `gh`'s default config: named when `gh` has several accounts, active when
    /// `viewer` is the only account, nil when the only account is someone else. Profile-loaded PRs write directly
    /// with their profile without re-probing all configs.
    static func writer(_ viewer: GitHubLogin, among accounts: [GitHubAccount]) -> GitHubAccountUse? {
        guard !accounts.isEmpty else { return .active }
        if accounts.count > 1 { return .named(viewer) }
        return viewer.matches(accounts[0].login.value) ? .active : nil
    }
}
