import Foundation
import GitaCore

/// The Worktrees & Agents pane's rows: one per agent session (subagents fold into their parent), then this
/// repository's worktrees without an agent, then the other monitored repositories' worktrees.
@MainActor
struct AgentsOverviewBuilder {
    var snapshot: RepositorySnapshot?
    var sessions: [AgentSession]
    var statuses: [RepositoryStatus]
    /// The monitor's status of a repository root.
    var status: (URL) -> RepositoryStatus?
    var signals: ProviderSignalQuery
    /// The checks of the commit with this ID.
    var checks: (String?) -> [ProviderItem]
    /// The comparable form of a path (`WindowAgents.key`).
    var key: (URL?) -> String?

    private var currentRoot: String? { key(snapshot?.root) }

    func rows() -> [AgentsPaneView.Row] {
        var rows: [AgentsPaneView.Row] = []
        var covered = Set<String>()
        for session in sessions where !WindowAgents.folds(session, in: sessions) {
            let checkout = session.checkoutRoot ?? session.workingDirectory
            let repository = session.repositoryRoot ?? checkout
            let checkoutKey = key(checkout) ?? checkout.path
            covered.insert(checkoutKey)
            let isMain = checkoutKey == key(repository)
            var row = AgentsPaneView.Row(
                id: session.id, session: session, repositoryName: repository.lastPathComponent,
                repositoryRoot: repository, checkoutPath: checkout.path,
                treeName: isMain ? "" : checkout.lastPathComponent, branch: session.branch ?? "", isMainCheckout: isMain
            )
            row.subagents = WindowAgents.subagents(of: session, in: sessions)
            rows.append(fill(row))
        }
        if let snapshot {
            let trees = snapshot.worktrees.filter { key(URL(fileURLWithPath: $0.path)) != currentRoot }
            for row in treeRows(trees, name: snapshot.root.lastPathComponent, root: snapshot.root, covered: &covered) {
                rows.append(fill(row))
            }
        }
        for status in statuses {
            rows += treeRows(status.worktrees, name: status.name, root: status.root, covered: &covered)
        }
        return rows
    }

    /// Rows for worktrees no row covers yet.
    private func treeRows(
        _ trees: [GitWorktree], name: String, root: URL, covered: inout Set<String>
    ) -> [AgentsPaneView.Row] {
        var rows: [AgentsPaneView.Row] = []
        for tree in trees where !tree.isBare {
            guard let treeKey = key(URL(fileURLWithPath: tree.path)), covered.insert(treeKey).inserted else {
                continue
            }
            rows.append(
                AgentsPaneView.Row(
                    id: "tree:" + treeKey, session: nil, repositoryName: name, repositoryRoot: root,
                    checkoutPath: tree.path, treeName: URL(fileURLWithPath: tree.path).lastPathComponent,
                    branch: tree.localizedBranch, isMainCheckout: false))
        }
        return rows
    }

    /// Adds what this window knows about the row's checkout: its branch, changes, pull request, checks and preview.
    private func fill(_ original: AgentsPaneView.Row) -> AgentsPaneView.Row {
        var row = original
        let checkoutKey = key(URL(fileURLWithPath: row.checkoutPath))
        let treeKeys = Set((snapshot?.worktrees ?? []).compactMap { key(URL(fileURLWithPath: $0.path)) })
        row.isCurrentRepository = checkoutKey == currentRoot || (checkoutKey.map(treeKeys.contains) ?? false)
        row.isOpenHere = checkoutKey != nil && checkoutKey == currentRoot
        if row.isCurrentRepository, let snapshot {
            if checkoutKey == currentRoot {
                fillMain(&row, snapshot: snapshot)
            } else if let tree = snapshot.worktrees.first(where: { key(URL(fileURLWithPath: $0.path)) == checkoutKey })
            {
                row.isMainCheckout = false
                let branch = tree.branch?.isEmpty == true ? nil : tree.localizedBranch
                row.branch = branch ?? row.branch
                row.pullRequest = signals.pullRequest(branch: branch)
                row.checks = checks(tree.head.isEmpty ? nil : tree.head)
            }
        } else if let status = status(row.repositoryRoot), key(status.root) == checkoutKey {
            row.ahead = status.ahead
            row.changed = status.changedFiles
            if let branch = status.branch { row.branch = branch }
        }
        return row
    }

    private func fillMain(_ row: inout AgentsPaneView.Row, snapshot: RepositorySnapshot) {
        let branch = snapshot.localizedBranch
        row.isMainCheckout = true
        row.branch = branch
        row.ahead = snapshot.ahead
        row.changed = snapshot.changes.count
        row.pullRequest = signals.pullRequest(branch: branch)
        row.checks = checks(snapshot.head)
        row.preview = signals.preview(branch: branch, head: snapshot.head)
    }
}
