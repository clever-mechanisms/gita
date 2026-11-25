import Foundation
import GitaCore

/// Where the collapsible `REPOSITORIES` drawer sits in the sidebar: above or below the open repository's pane.
enum SidebarRepositoriesPosition: String, CaseIterable, Sendable {
    case top
    case bottom

    static let `default`: Self = .bottom

    init(stored raw: String) {
        self = Self(rawValue: raw) ?? .default
    }

    var title: String {
        switch self {
        case .top: String(localized: "Top")
        case .bottom: String(localized: "Bottom")
        }
    }

    var menuTitle: String {
        switch self {
        case .top: String(localized: "Show at Top")
        case .bottom: String(localized: "Show at Bottom")
        }
    }
}

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

    private static let collapsedKey = "sidebarRepositoriesCollapsed"
    private static let heightKey = "sidebarRepositoriesHeight"
    private static let mruCheckoutsKey = "sidebarMRUCheckouts"

    /// Repository root path → expanded.
    var repositoryExpansion: [String: Bool] {
        didSet { remember(repositoryExpansion, .sidebarRepositories) }
    }
    /// `SidebarGroupID.persistedKey` → expanded.
    private(set) var groupExpansion: [String: Bool] {
        didSet { remember(groupExpansion, .sidebarGroups) }
    }
    /// Whether the pinned Repositories drawer is collapsed to its header.
    var repositoriesCollapsed: Bool {
        didSet { defaults.set(repositoriesCollapsed, forKey: Self.collapsedKey) }
    }
    /// Whether Repositories sits at the top or bottom of the sidebar split.
    var repositoriesPosition: SidebarRepositoriesPosition {
        SidebarRepositoriesPosition(stored: Preference.sidebarRepositoriesPosition.string(defaults))
    }
    /// Remembered height of the Repositories drawer before the 40% cap. Zero means use the default share.
    var repositoriesHeight: CGFloat {
        didSet { defaults.set(Double(repositoriesHeight), forKey: Self.heightKey) }
    }
    /// Canonical repository root path → most recently opened checkout path.
    private(set) var mruCheckouts: [String: String] {
        didSet { defaults.set(mruCheckouts, forKey: Self.mruCheckoutsKey) }
    }

    func setExpanded(_ group: SidebarGroupID, _ expanded: Bool) { groupExpansion[group.persistedKey] = expanded }
    private(set) var repositoryOrder: RepositoryListOrder

    init(defaults: UserDefaults) {
        self.defaults = defaults
        repositoryExpansion = Self.remembered(.sidebarRepositories, in: defaults)
        let opened = [SidebarGroupID.branches.persistedKey: true, SidebarGroupID.worktrees.persistedKey: true]
        groupExpansion = opened.merging(Self.remembered(.sidebarGroups, in: defaults)) { $1 }
        repositoriesCollapsed = defaults.bool(forKey: Self.collapsedKey)
        repositoriesHeight = CGFloat(defaults.double(forKey: Self.heightKey))
        mruCheckouts = defaults.dictionary(forKey: Self.mruCheckoutsKey) as? [String: String] ?? [:]
        repositoryOrder = RepositoryListOrder(rawValue: Preference.sidebarRepositoryOrder.string(defaults)) ?? .name
    }

    func recordCheckout(_ checkoutURL: URL, for repositoryRoot: URL) {
        let rootKey = RecentRepositories.canonical(repositoryRoot.path)
        let checkoutPath = RecentRepositories.canonical(checkoutURL.path)
        guard mruCheckouts[rootKey] != checkoutPath else { return }
        mruCheckouts[rootKey] = checkoutPath
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

    /// Every tab's sidebar listens for the change and moves the Repositories drawer.
    func setRepositoriesPosition(_ position: SidebarRepositoriesPosition) {
        Preference.sidebarRepositoriesPosition.set(position.rawValue, defaults)
    }

    /// Forgets the open-or-closed state of repositories removed from the list (any spelling of their paths).
    func forgetRepositories(_ paths: [String]) {
        let gone = Set(paths.map(RecentRepositories.canonical))
        let kept = repositoryExpansion.filter { !gone.contains(RecentRepositories.canonical($0.key)) }
        if kept.count != repositoryExpansion.count { repositoryExpansion = kept }
        let keptMRU = mruCheckouts.filter { !gone.contains($0.key) }
        if keptMRU.count != mruCheckouts.count { mruCheckouts = keptMRU }
    }
}
