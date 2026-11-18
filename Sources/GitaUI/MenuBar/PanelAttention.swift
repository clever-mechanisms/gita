import Foundation
import GitaCore

/// Pure: the repositories in the workspaces' tabs and the agents → what waits for the user. These are the panel's
/// "Needs you" cards, and the menu bar icon's dot is lit exactly while there is one.
@MainActor
enum PanelAttention {
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable {
            /// An agent waits for input: its terminal comes forward.
            case agentWaiting(tool: AgentTool, session: String)
            /// A review is requested from the user: the pull request's page opens.
            case reviewRequested
            /// Checks fail on the repository's current branch: the failing run opens.
            case checksFailed
            /// The active repository has conflicts: it is shown in Gitā.
            case conflicts
        }
        let id: String
        let kind: Kind
        /// The repository it is about; shown in Gitā when there is no page to open.
        let repository: URL
        /// "repository · worktree · task", "repository · #482 title", "repository · branch · run name".
        let detail: String
        /// Since when it waits; nil for conflicts, which are there now.
        var date: Date?
        /// The page to open: the pull request or the failing run.
        var url: URL?
    }

    /// What the items are built from.
    struct Source {
        var repositories: [MenuPanelState.Repository] = []
        var sessions: [AgentSession] = []
        /// Display names by `ProviderActivity.key`.
        var names: [String: String] = [:]
        /// The active repository, while it has conflicts.
        var conflicts: URL?
    }

    /// Conflicts first, then the newest; ties keep one order.
    static func items(_ source: Source) -> [Item] {
        let items =
            source.sessions.filter { $0.state == .needsInput }.map { agent($0, source) }
            + source.repositories.flatMap(reviews) + source.repositories.compactMap(checks)
            + [source.conflicts.map { conflicts($0, source) }].compactMap { $0 }
        return items.sorted {
            let (lhs, rhs) = ($0.date ?? .distantFuture, $1.date ?? .distantFuture)
            return lhs != rhs ? lhs > rhs : $0.id < $1.id
        }
    }

    private static func name(_ url: URL, _ source: Source) -> String {
        source.names[ProviderActivity.key(url)] ?? url.lastPathComponent
    }

    private static func agent(_ session: AgentSession, _ source: Source) -> Item {
        let repository = PanelRowBuilder.home(session)
        let checkout = session.checkoutRoot ?? session.workingDirectory
        let inWorktree = ProviderActivity.key(checkout) != ProviderActivity.key(repository)
        let facts = [name(repository, source), inWorktree ? checkout.lastPathComponent : nil, session.title]
        return Item(
            id: "agent:" + session.id, kind: .agentWaiting(tool: session.tool, session: session.id),
            repository: checkout, detail: detail(facts), date: session.stateSince)
    }

    private static func reviews(_ repository: MenuPanelState.Repository) -> [Item] {
        repository.pullRequests.filter(\.reviewRequested).map { pullRequest in
            Item(
                id: "review:\(repository.id)#\(pullRequest.number)", kind: .reviewRequested,
                repository: repository.root,
                detail: detail([repository.name, "#\(pullRequest.number) \(pullRequest.title)"]),
                date: pullRequest.date, url: pullRequest.url)
        }
    }

    private static func checks(_ repository: MenuPanelState.Repository) -> Item? {
        guard let checks = repository.checks, checks.state == .failure else { return nil }
        return Item(
            id: "checks:" + repository.id, kind: .checksFailed, repository: repository.root,
            detail: detail([repository.name, repository.branch, checks.run.name]), date: checks.run.date,
            url: checks.run.url)
    }

    private static func conflicts(_ root: URL, _ source: Source) -> Item {
        let repository = source.repositories.first { ProviderActivity.key($0.root) == ProviderActivity.key(root) }
        return Item(
            id: "conflicts:" + MenuPanelState.Repository.id(root), kind: .conflicts, repository: root,
            detail: detail([repository?.name ?? name(root, source), repository?.branch]))
    }

    private static func detail(_ facts: [String?]) -> String {
        facts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
