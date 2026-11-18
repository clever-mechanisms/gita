import Foundation
import GitaCore

/// What the user opened or closed in the sidebar and the order of Repositories: shared by every tab's sidebar and
/// remembered across launches (switching to another checkout of the same repository keeps the list's shape; a
/// relaunch keeps it too).
@MainActor
final class SidebarState {
    private static var instances: [ObjectIdentifier: SidebarState] = [:]

    /// The state every sidebar reading `defaults` shares.
    static func shared(_ defaults: UserDefaults) -> SidebarState {
        if let state = instances[ObjectIdentifier(defaults)] { return state }
        let state = SidebarState(defaults: defaults)
        instances[ObjectIdentifier(defaults)] = state
        return state
    }

    let defaults: UserDefaults

    /// Repository root path → expanded.
    var repositoryExpansion: [String: Bool] {
        didSet { remember(repositoryExpansion, .sidebarRepositories) }
    }
    /// `SidebarGroupID.persistedKey` → expanded.
    private(set) var groupExpansion: [String: Bool] {
        didSet { remember(groupExpansion, .sidebarGroups) }
    }

    func setExpanded(_ group: SidebarGroupID, _ expanded: Bool) { groupExpansion[group.persistedKey] = expanded }
    private(set) var repositoryOrder: RepositoryListOrder

    init(defaults: UserDefaults) {
        self.defaults = defaults
        repositoryExpansion = Self.remembered(.sidebarRepositories, in: defaults)
        let opened = [SidebarGroupID.branches.persistedKey: true, SidebarGroupID.worktrees.persistedKey: true]
        groupExpansion = opened.merging(Self.remembered(.sidebarGroups, in: defaults)) { $1 }
        repositoryOrder = RepositoryListOrder(rawValue: Preference.sidebarRepositoryOrder.string(defaults)) ?? .name
    }

    private static func remembered(_ key: Preference, in defaults: UserDefaults) -> [String: Bool] {
        defaults.dictionary(forKey: key.rawValue) as? [String: Bool] ?? [:]
    }

    private func remember(_ value: [String: Bool], _ key: Preference) {
        // Written straight to the store: UI state, nothing listens for it.
        defaults.set(value, forKey: key.rawValue)
    }

    /// Every tab's sidebar listens for the change and re-sorts.
    func setRepositoryOrder(_ order: RepositoryListOrder) {
        repositoryOrder = order
        Preference.sidebarRepositoryOrder.set(order.rawValue, defaults)
    }

    /// Forgets the open-or-closed state of repositories removed from the list (any spelling of their paths).
    func forgetRepositories(_ paths: [String]) {
        let gone = Set(paths.map(RecentRepositories.canonical))
        let kept = repositoryExpansion.filter { !gone.contains(RecentRepositories.canonical($0.key)) }
        guard kept.count != repositoryExpansion.count else { return }
        repositoryExpansion = kept
    }
}
