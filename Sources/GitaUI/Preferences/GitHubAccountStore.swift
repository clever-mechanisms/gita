import Foundation
import GitaCore

/// The `gh` account each GitHub repository is read as, by `GitHubRemote.sourceID`: one the user chose, or one Gita
/// found that could see the repository. Stored as `automatic:<login>` or `chosen:<login>` (with optional
/// `@<gh-profile>` for accounts in a sibling `GH_CONFIG_DIR`); logins and profile names only, never tokens.
struct GitHubAccountStore {
    struct Assignment: Equatable, Sendable {
        var sourceID: String
        var choice: GitHubAccountChoice

        var isChosen: Bool {
            if case .chosen = choice { true } else { false }
        }
    }

    var defaults: UserDefaults = Preference.store

    private static let automaticPrefix = "automatic:"
    private static let chosenPrefix = "chosen:"
    private static let profileSeparator: Character = "@"

    func choice(for sourceID: String?) -> GitHubAccountChoice? {
        guard let sourceID, let value = entries[sourceID] else { return nil }
        return Self.choice(from: value)
    }

    /// Every valid stored assignment, ordered by `sourceID`.
    func allAssignments() -> [Assignment] {
        entries.compactMap { sourceID, raw in
            Self.choice(from: raw).map { Assignment(sourceID: sourceID, choice: $0) }
        }.sorted { $0.sourceID.localizedStandardCompare($1.sourceID) == .orderedAscending }
    }

    /// The account the repository's reads and detail views run as.
    func use(for sourceID: String?) -> GitHubAccountUse {
        choice(for: sourceID).map { .named($0.accountID) } ?? .active
    }

    /// What a list read learned. A user's choice is never replaced by Gita.
    func apply(_ update: GitHubAccountUpdate, sourceID: String?) {
        guard let sourceID else { return }
        if case .chosen = choice(for: sourceID) { return }
        switch update {
        case .keep: return
        case .store(let login, let profile):
            set(.automatic(login, profile: profile), sourceID: sourceID)
        case .forget: set(nil, sourceID: sourceID)
        }
    }

    /// The user's pick on the GitHub page or in Settings; nil goes back to automatic.
    func choose(_ account: GitHubAccountID?, sourceID: String) {
        set(account.map(GitHubAccountChoice.chosen), sourceID: sourceID)
    }

    /// Clears any stored assignment (chosen or automatic) for `sourceID`.
    func reset(sourceID: String) {
        set(nil, sourceID: sourceID)
    }

    private func set(_ choice: GitHubAccountChoice?, sourceID: String) {
        var stored = entries
        stored[sourceID] = choice.map(Self.storage)
        Preference.githubAccounts.set(stored, defaults)
    }

    private var entries: [String: String] {
        defaults.dictionary(forKey: Preference.githubAccounts.rawValue) as? [String: String] ?? [:]
    }

    static func displayName(for sourceID: String) -> String {
        for prefix in ["github.com/", "github:"] where sourceID.hasPrefix(prefix) {
            return String(sourceID.dropFirst(prefix.count))
        }
        return sourceID
    }

    /// Encodes a `GitHubAccountID` as `<login>` (default config) or `<login>@<profile>` (sibling `GH_CONFIG_DIR`).
    static func accountKey(for account: GitHubAccountID) -> String {
        guard let profile = account.profile else { return account.login.value }
        return account.login.value + String(profileSeparator) + profile.name
    }

    /// Decodes a `GitHubAccountID` previously encoded with `accountKey(for:)`.
    static func accountID(from key: String) -> GitHubAccountID? {
        if let separator = key.firstIndex(of: profileSeparator) {
            let loginPart = String(key[..<separator])
            let profilePart = String(key[key.index(after: separator)...])
            guard let login = GitHubLogin(loginPart), let profile = GitHubConfigProfile(profilePart) else { return nil }
            return GitHubAccountID(login, profile: profile)
        }
        return GitHubLogin(key).map { GitHubAccountID($0) }
    }

    static func storage(_ choice: GitHubAccountChoice) -> String {
        switch choice {
        case .automatic: automaticPrefix + accountKey(for: choice.accountID)
        case .chosen: chosenPrefix + accountKey(for: choice.accountID)
        }
    }

    static func choice(from value: String) -> GitHubAccountChoice? {
        if value.hasPrefix(automaticPrefix) {
            return accountID(from: String(value.dropFirst(automaticPrefix.count))).map(GitHubAccountChoice.automatic)
        }
        if value.hasPrefix(chosenPrefix) {
            return accountID(from: String(value.dropFirst(chosenPrefix.count))).map(GitHubAccountChoice.chosen)
        }
        return nil
    }
}
