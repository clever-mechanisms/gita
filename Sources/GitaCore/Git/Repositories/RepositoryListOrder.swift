import Foundation

/// How a list of repositories is ordered: the sidebar's Repositories (Name · Recently Opened · Status) and the
/// groups of the Worktrees & Agents pane (Status · Name). Stored as the raw value in the app's preferences.
public enum RepositoryListOrder: String, CaseIterable, Sendable {
    case name, recent, status

    /// A sorted copy. `.recent` keeps the order given (tabs, then most recently opened). `.name` is Finder's order
    /// (`localizedStandardCompare`: case-insensitive, numbers by value). `.status` puts the lowest `rank` first and
    /// orders equal ranks by name. Items that still tie keep the order given.
    public func sorted<Item>(_ items: [Item], name: (Item) -> String, rank: (Item) -> Int) -> [Item] {
        switch self {
        case .recent: return items
        case .name, .status:
            let keyed = items.enumerated().map {
                (
                    offset: $0.offset, item: $0.element, name: name($0.element),
                    rank: self == .status ? rank($0.element) : 0
                )
            }
            return keyed.sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }.map(\.item)
        }
    }

    /// A sidebar repository's place in `.status`: an agent waiting for input, then a working agent, then local changes
    /// or commits ahead, then the rest.
    public static func statusRank(needsInput: Bool, working: Bool, hasChanges: Bool) -> Int {
        needsInput ? 0 : working ? 1 : hasChanges ? 2 : 3
    }
}

/// The "recently opened repositories" list kept in the preferences: most recent first, at most `limit` paths.
public enum RecentRepositories {
    public static let limit = 12

    /// The path every spelling of a folder shares: standardized (`..`, `.`, trailing slash) and symlinks resolved.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The list without any entry naming one of `paths` (however either is spelled).
    public static func removing(_ paths: [String], from list: [String]) -> [String] {
        let gone = Set(paths.map(canonical))
        return list.filter { !gone.contains(canonical($0)) }
    }

    /// `path` first (any other spelling of it dropped), the rest after it, cut to `limit`.
    public static func inserting(_ path: String, into list: [String]) -> [String] {
        Array(([path] + removing([path], from: list)).prefix(limit))
    }
}
