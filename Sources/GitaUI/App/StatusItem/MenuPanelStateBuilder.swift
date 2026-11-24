import Foundation
import GitaCore

/// The menu bar panel's contents, projected from the workspaces, their repositories' statuses, the open repository,
/// the provider activity and the agents.
@MainActor
struct MenuPanelStateBuilder {
    var activity: ProviderActivity
    var agents: AgentMonitor

    /// Statuses for `urls` before the workspace monitor reports: names only, "parent/name" when two share a name.
    static func placeholders(_ urls: [URL]) -> [RepositoryStatus] {
        let names = RepositoryStatus.displayNames(urls)
        return urls.map { RepositoryStatus(root: $0, name: names[$0.path] ?? $0.lastPathComponent) }
    }

    /// What the app shell knows: the monitored repositories, the workspaces and the active repository.
    struct Shell {
        var statuses: [RepositoryStatus] = []
        var workspaces: [MenuPanelState.Workspace] = []
        var snapshot: RepositorySnapshot?
        var hasConflicts = false
        var isRefreshing = false
    }

    /// The repositories in some workspace's tabs, and every monitored repository's display name. The monitor also
    /// follows the recent repositories, which the panel does not list.
    private func repositories(_ shell: Shell) -> (shown: [MenuPanelState.Repository], names: [String: String]) {
        let tabs = Set(shell.workspaces.flatMap(\.repositories))
        var names: [String: String] = [:]
        var shown: [MenuPanelState.Repository] = []
        for status in shell.statuses {
            names[ProviderActivity.key(status.root)] = status.name
            if tabs.contains(status.id) { shown.append(repository(status, snapshot: shell.snapshot)) }
        }
        return (shown, names)
    }

    /// What waits for the user: all the menu bar icon needs, without the rest of the panel.
    func attention(_ shell: Shell) -> [PanelAttention.Item] {
        let (repositories, names) = repositories(shell)
        return attention(shell, repositories: repositories, names: names)
    }

    private func attention(
        _ shell: Shell, repositories: [MenuPanelState.Repository], names: [String: String]
    ) -> [PanelAttention.Item] {
        PanelAttention.items(
            .init(
                repositories: repositories, sessions: agents.sessions, names: names,
                conflicts: shell.hasConflicts ? shell.snapshot?.root : nil))
    }

    func build(_ shell: Shell) -> MenuPanelState {
        let (repositories, names) = repositories(shell)
        let sessions = agents.sessions
        let checked = ([activity.checkedAt] + shell.statuses.map(\.checkedAt)).compactMap { $0 }.max()
        let problem = activity.problemDetail(names: names)
        return MenuPanelState(
            repositories: repositories, workspaces: MenuPanelState.Workspace.ordered(shell.workspaces),
            attention: attention(shell, repositories: repositories, names: names), sessions: sessions, names: names,
            feed: activity.feed(sessions: sessions, names: names), problem: problem?.text, problemDetail: problem,
            checkedAt: checked, isRefreshing: shell.isRefreshing)
    }

    private func repository(_ status: RepositoryStatus, snapshot: RepositorySnapshot?) -> MenuPanelState.Repository {
        var repository = MenuPanelState.Repository(
            root: status.root, name: status.name, branch: status.branch, ahead: status.ahead, behind: status.behind,
            changedFiles: status.changedFiles, worktrees: status.worktrees.count)
        repository.error = status.error
        if let snapshot, ProviderActivity.key(snapshot.root) == ProviderActivity.key(status.root) {
            // The open tab is fresher than the light status.
            repository.branch = snapshot.localizedBranch
            repository.ahead = snapshot.ahead
            repository.behind = snapshot.behind
            repository.changedFiles = snapshot.changes.count
            repository.error = nil
        }
        let entry = activity.entry(for: status.root)
        let items = entry?.items ?? []
        let branch = repository.branch ?? entry?.branch
        repository.checks = ProviderActivity.checks(items, branch: branch)
        repository.preview =
            ProviderActivity.deployments(items, branch: branch, vercel: entry?.reports[.vercel]?.vercel).preview
        repository.pullRequests = ProviderActivity.pullRequests(items)
        repository.agents = agents.summary(forRepository: status.root)
        return repository
    }
}
