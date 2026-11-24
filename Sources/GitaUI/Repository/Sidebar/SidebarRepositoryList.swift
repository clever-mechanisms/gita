import Foundation
import GitaCore

/// The sidebar's Repositories: one row per repository, in the monitor's order, whichever of its checkouts is open. A
/// linked worktree opened in a tab shows as its repository's checkout row, selected in place; opening a checkout
/// never moves the list under the pointer.
@MainActor
struct SidebarRepositoryList {
    typealias Repository = RepositorySidebarView.Repository
    typealias Checkout = RepositorySidebarView.Checkout

    /// The recent repositories listed while the monitor has none.
    static let recentLimit = 12

    var snapshot: RepositorySnapshot?
    var statuses: [RepositoryStatus]
    var status: (URL) -> RepositoryStatus?
    var openRepositories: [URL]
    var recent: [String]
    /// The checkouts being opened (their keys).
    var loading: Set<String>
    /// The comparable form of a path (`WindowAgents.key`).
    var key: (URL?) -> String?
    var sessionsAt: (URL) -> [AgentSession]
    var sessionsIn: (URL) -> [AgentSession]
    /// Most recently used checkout per canonical repository root.
    var mruCheckouts: [String: String] = [:]
    /// Repository keys (`WindowAgents.key`) whose remote moved per `RemoteMonitor`.
    var remoteMovedRoots: Set<String> = []
    /// Checkout keys (`WindowAgents.key`) whose current branch upstream moved per `RemoteMonitor`.
    var remoteMovedCheckouts: Set<String> = []

    private func key(_ path: String) -> String? { key(URL(fileURLWithPath: path)) }
    private var currentKey: String? { key(snapshot?.root) }
    private var trees: [GitWorktree] { snapshot?.worktrees ?? [] }

    func repositories() -> [Repository] {
        let mainOf = mainCheckouts()
        var roots = initialRoots()
        var listed = Set(roots.compactMap { key($0) })
        // The open checkout's repository: its main checkout when a linked worktree is open.
        let groupKey = currentKey.flatMap { mainOf[$0] } ?? currentKey
        if let root = snapshot?.root, let groupKey, !listed.contains(groupKey) {
            // Not listed yet (the monitor follows the next session change): after the open tabs, where it will land,
            // and as the repository (its main checkout), never as a worktree of its own.
            let open = Set(openRepositories.compactMap { key($0) })
            let index = roots.lastIndex { key($0).map(open.contains) == true }.map { $0 + 1 } ?? 0
            roots.insert(groupKey == currentKey ? root : URL(fileURLWithPath: groupKey, isDirectory: true), at: index)
            listed.insert(groupKey)
        }
        var seen = Set<String>()
        var result: [Repository] = []
        for root in roots {
            guard let rootKey = key(root), seen.insert(rootKey).inserted else { continue }
            // A linked worktree listed on its own (an open tab, a recent repository) shows inside its repository.
            if let main = mainOf[rootKey], main != rootKey, listed.contains(main) { continue }
            result.append(repository(root, key: rootKey, isCurrent: rootKey == groupKey))
        }
        return result
    }

    private func initialRoots() -> [URL] {
        let roots = statuses.map(\.root)
        guard roots.isEmpty else { return roots }
        return openRepositories + recent.prefix(Self.recentLimit).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Linked worktree → its main checkout: from each main checkout's light status (linked worktrees only) and from
    /// this tab's own worktree list, which names the main checkout first.
    private func mainCheckouts() -> [String: String] {
        var mainOf: [String: String] = [:]
        for status in statuses {
            guard let main = key(status.root) else { continue }
            let linked = status.worktrees.compactMap { key($0.path) }
            if linked.contains(main) { continue } // the status of a linked worktree opened on its own
            for tree in linked { mainOf[tree] = main }
        }
        if let first = trees.first, !first.isBare, let main = key(first.path) {
            for tree in trees.dropFirst() {
                if let linked = key(tree.path) { mainOf[linked] = main }
            }
        }
        return mainOf
    }

    private func repository(_ root: URL, key rootKey: String, isCurrent: Bool) -> Repository {
        let status = status(root)
        var ahead = status?.ahead ?? 0
        var behind = status?.behind ?? 0
        var changed = status?.changedFiles ?? 0
        let checkouts: [Checkout]
        if isCurrent, let snapshot, let first = trees.first, !first.isBare,
            key(first.path) != currentKey
        {
            behind = max(behind, snapshot.behind)
            checkouts = linkedWorktreeCheckouts(snapshot, rootKey: rootKey, status: status)
        } else if isCurrent, let snapshot {
            ahead = snapshot.ahead
            behind = snapshot.behind
            changed = snapshot.changes.count
            checkouts = currentCheckouts(snapshot, rootKey: rootKey)
        } else if let status {
            checkouts = statusCheckouts(root, status: status)
        } else {
            checkouts = sessionCheckouts(root)
        }
        let moved = remoteMovedRoots.contains(rootKey) || checkouts.contains(where: \.remoteMoved)
        return Repository(
            root: root, name: status?.name ?? root.lastPathComponent,
            badge: Self.badge(ahead: ahead, behind: behind, changed: changed, remoteMoved: moved),
            badgeIsChange: ahead == 0 && behind == 0 && !moved && changed > 0, isCurrent: isCurrent,
            checkouts: checkouts, error: status?.error, behind: behind, remoteMoved: moved,
            mruCheckoutPath: mruCheckoutPath(for: rootKey, checkouts: checkouts))
    }

    private func mruCheckoutPath(for rootKey: String, checkouts: [Checkout]) -> String? {
        let checkoutKeys = Set(checkouts.compactMap { key($0.path) })
        if let stored = mruCheckouts[rootKey], let storedKey = key(stored), checkoutKeys.contains(storedKey) {
            return stored
        }
        return recent.first { path in
            guard let candidate = key(path) else { return false }
            return checkoutKeys.contains(candidate)
        }
    }

    static func badge(ahead: Int, behind: Int = 0, changed: Int, remoteMoved: Bool = false) -> String {
        var parts: [String] = []
        if behind > 0 { parts.append("↓\(behind)") } else if remoteMoved { parts.append("⇣") }
        if ahead > 0 { parts.append("↑\(ahead)") }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return changed > 0 ? String(localized: "\(changed) changed") : ""
    }

    private struct CheckoutMetrics {
        var ahead = 0
        var behind = 0
        var locked = false
    }

    /// A linked worktree is open: the repository's checkouts in the worktree list's order (main first).
    private func linkedWorktreeCheckouts(
        _ snapshot: RepositorySnapshot, rootKey: String, status: RepositoryStatus?
    ) -> [Checkout] {
        trees.enumerated().compactMap { index, tree in
            guard !tree.isBare else { return nil }
            let here = key(tree.path)
            let ahead = here == currentKey ? snapshot.ahead : here == rootKey ? status?.ahead ?? 0 : 0
            let behind = here == currentKey ? snapshot.behind : here == rootKey ? status?.behind ?? 0 : 0
            return checkout(
                tree.path, branch: here == currentKey ? snapshot.localizedBranch : Self.label(tree),
                isMain: index == 0, metrics: CheckoutMetrics(ahead: ahead, behind: behind, locked: tree.isLocked))
        }
    }

    private func currentCheckouts(_ snapshot: RepositorySnapshot, rootKey: String) -> [Checkout] {
        [
            checkout(
                snapshot.root.path, branch: snapshot.localizedBranch, isMain: true,
                metrics: CheckoutMetrics(ahead: snapshot.ahead, behind: snapshot.behind))
        ]
            + trees.filter { !$0.isBare && key($0.path) != rootKey }.map {
                checkout(
                    $0.path, branch: Self.label($0), isMain: false,
                    metrics: CheckoutMetrics(locked: $0.isLocked))
            }
    }

    private func statusCheckouts(_ root: URL, status: RepositoryStatus) -> [Checkout] {
        [
            checkout(
                root.path, branch: status.branch ?? String(localized: "Detached"), isMain: true,
                metrics: CheckoutMetrics(ahead: status.ahead, behind: status.behind))
        ]
            + status.worktrees.filter { !$0.isBare }.map {
                checkout(
                    $0.path, branch: Self.label($0), isMain: false,
                    metrics: CheckoutMetrics(locked: $0.isLocked))
            }
    }

    /// A repository the monitor does not know yet: its agents' checkout, if any.
    private func sessionCheckouts(_ root: URL) -> [Checkout] {
        let sessions = sessionsIn(root)
        guard let lead = sessions.first else { return [] }
        return [
            Checkout(
                path: root.path, branch: lead.branch ?? root.lastPathComponent, sessions: sessions, meta: "",
                isMain: true)
        ]
    }

    private func checkout(_ path: String, branch: String, isMain: Bool, metrics: CheckoutMetrics) -> Checkout {
        let url = URL(fileURLWithPath: path)
        let checkoutKey = key(url)
        let moved = checkoutKey.map(remoteMovedCheckouts.contains) == true
        var result = Checkout(
            path: path, branch: branch, sessions: sessionsAt(url), meta: "",
            isMain: isMain, isLocked: metrics.locked,
            isLoading: checkoutKey.map(loading.contains) == true,
            behind: metrics.behind, remoteMoved: moved)
        let aheadText = metrics.ahead > 0 ? "↑\(metrics.ahead)" : ""
        result.meta = [result.remoteUpdateText, aheadText].filter { !$0.isEmpty }.joined(separator: " ")
        return result
    }

    private static func label(_ tree: GitWorktree) -> String {
        tree.branch?.isEmpty == true ? URL(fileURLWithPath: tree.path).lastPathComponent : tree.localizedBranch
    }
}
