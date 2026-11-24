import Foundation
import GitaCore

/// The `gh` account each GitHub repository is read as, by `GitHubRemote.sourceID`: one the user chose, or one Gita
/// found that could see the repository. Stored as `automatic:<login>` or `chosen:<login>`; logins only, never a token.
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
        choice(for: sourceID).map { .named($0.login) } ?? .active
    }

    /// What a list read learned. A user's choice is never replaced by Gita.
    func apply(_ update: GitHubAccountUpdate, sourceID: String?) {
        guard let sourceID else { return }
        if case .chosen = choice(for: sourceID) { return }
        switch update {
        case .keep: return
        case .store(let login): set(.automatic(login), sourceID: sourceID)
        case .forget: set(nil, sourceID: sourceID)
        }
    }

    /// The user's pick on the GitHub page or in Settings; nil goes back to automatic.
    func choose(_ login: GitHubLogin?, sourceID: String) {
        set(login.map(GitHubAccountChoice.chosen), sourceID: sourceID)
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

    static func storage(_ choice: GitHubAccountChoice) -> String {
        switch choice {
        case .automatic(let login): automaticPrefix + login.value
        case .chosen(let login): chosenPrefix + login.value
        }
    }

    static func choice(from value: String) -> GitHubAccountChoice? {
        if value.hasPrefix(automaticPrefix) {
            return GitHubLogin(String(value.dropFirst(automaticPrefix.count))).map(GitHubAccountChoice.automatic)
        }
        if value.hasPrefix(chosenPrefix) {
            return GitHubLogin(String(value.dropFirst(chosenPrefix.count))).map(GitHubAccountChoice.chosen)
        }
        return nil
    }
}
