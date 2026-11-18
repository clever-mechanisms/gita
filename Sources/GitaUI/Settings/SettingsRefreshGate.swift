import Foundation

/// Decides whether a defaults change concerns Settings. The store also holds window state (tab sessions, sidebar
/// groups, author colours) that changes all the time; only a change to a value the panes show refreshes them.
struct SettingsRefreshGate {
    /// Settings no pane shows: window and list state kept in the same store.
    static let windowState: Set<Preference> = [
        .settingsPane, .authorColors, .sidebarGroups, .sidebarRepositories, .agentsPaneShown,
        .sidebarRepositoryOrder, .filesAsTree, .agentsPaneOrder, .silencedRepositories, .githubAccounts,
    ]
    static let shown = Preference.allCases.filter { !windowState.contains($0) }

    private var last: [String: String] = [:]
    private var hasRecorded = false

    /// The shown settings' current values, comparable between two reads.
    static func snapshot(_ defaults: UserDefaults) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: shown.map { preference in
                (preference.rawValue, defaults.object(forKey: preference.rawValue).map { "\($0)" } ?? "")
            })
    }
    /// True when a shown setting differs from the last call (the first call only records them).
    mutating func changed(_ defaults: UserDefaults) -> Bool {
        let next = Self.snapshot(defaults)
        defer { record(next) }
        return hasRecorded && last != next
    }
    /// Records the current values without reporting a change (after a refresh for another reason).
    mutating func record(_ defaults: UserDefaults) { record(Self.snapshot(defaults)) }
    private mutating func record(_ values: [String: String]) {
        last = values
        hasRecorded = true
    }
}
