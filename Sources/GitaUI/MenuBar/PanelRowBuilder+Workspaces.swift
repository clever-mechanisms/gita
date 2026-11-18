import Foundation
import GitaCore

/// Workspaces: one card each, the front one first, then those in other windows, then the closed ones. A card names
/// the workspace and where it is, and shows its tabs as pills; a click opens the workspace, a pill its tab. Without
/// a window the card is an outline with an Open chip; its pills are labels, unless it is the workspace Gitā keeps
/// while its last window is closed, whose tabs open with the window.
extension PanelRowBuilder {
    func workspaceRows() -> [PanelRow] {
        guard !state.workspaces.isEmpty else { return [] }
        let repositories = Dictionary(state.repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return [header("workspaces", String(localized: "Workspaces"))]
            + state.workspaces.map { workspaceRow($0, repositories) }
    }

    private func workspaceRow(
        _ workspace: MenuPanelState.Workspace, _ repositories: [String: MenuPanelState.Repository]
    ) -> PanelRow {
        var row = PanelRow(
            id: "workspace:" + workspace.id, kind: .workspace,
            lead: .symbol(Deck.workspaceSymbol, .secondary), title: workspace.title,
            action: .openWorkspace(workspace.id))
        let state: String
        switch workspace.presence {
        case .front:
            state = String(localized: "In front")
            row.lead = .symbol(Deck.workspaceSymbol, .accentText)
            row.status = state
            row.statusColor = .accentText
        case .window:
            state = String(localized: "Window")
            row.status = state
        case .resting, .closed:
            state = String(localized: "Closed")
            row.lead = .symbol(Deck.workspaceSymbol, .tertiary)
            row.suffix = state
            row.outlined = true
            row.chips = [
                PanelChip(
                    title: String(localized: "Open"), action: .openWorkspace(workspace.id),
                    label: String(localized: "Open “\(workspace.title)”"))
            ]
        }
        row.pills = workspace.repositories.map { id in
            let repository =
                repositories[id]
                ?? Self.unread(URL(fileURLWithPath: id, isDirectory: true))
            return pill(repository, in: workspace)
        }
        // Its pills name its repositories themselves.
        row.label = workspace.title + ", " + state
        return row
    }

    /// A tab the monitor has not reported yet: named after its folder.
    private static func unread(_ root: URL) -> MenuPanelState.Repository {
        MenuPanelState.Repository(root: root, name: root.lastPathComponent)
    }

    /// A tab: the repository's most urgent mark (an agent's unless it idles, else its checks'), its name, and ↑n ↓n.
    /// A closed workspace's pill is a label: showing its tab would take a window from another workspace.
    private func pill(_ repository: MenuPanelState.Repository, in workspace: MenuPanelState.Workspace) -> PanelPill {
        var pill = PanelPill(id: repository.id, title: repository.name)
        if let agent = Self.agentMark(repository, sessions: state.sessions), agent.state != .idle {
            pill.mark = .agent(agent)
        } else if let checks = repository.checks {
            pill.mark = .checks(checks.state)
        }
        let counts = [
            repository.ahead > 0 ? "↑\(repository.ahead)" : nil, repository.behind > 0 ? "↓\(repository.behind)" : nil,
        ].compactMap { $0 }
        pill.counts = counts.isEmpty ? nil : counts.joined(separator: " ")
        pill.tinted = repository.agents.needsInput > 0
        if workspace.presence != .closed {
            pill.action = .showTab(repository.root, workspace: workspace.id)
            pill.menu = Self.menu(repository, show: .showTab(repository.root, workspace: workspace.id))
        }
        pill.toolTip = Self.toolTip(repository)
        pill.width = PanelPillButton.width(pill)
        return pill
    }

    /// Show in Gitā, Push n, Open Preview, Copy Path.
    private static func menu(_ repository: MenuPanelState.Repository, show: PanelAction) -> [PanelPill.MenuEntry] {
        var menu = [PanelPill.MenuEntry(title: String(localized: "Show in Gitā"), symbol: "macwindow", action: show)]
        if repository.ahead > 0 {
            menu.append(
                .init(
                    title: String(localized: "Push \(repository.ahead)"), symbol: "arrow.up",
                    action: .push(repository.root)))
        }
        if let preview = repository.preview {
            menu.append(.init(title: String(localized: "Open Preview"), symbol: "globe", action: .openURL(preview.url)))
        }
        menu.append(
            .init(title: String(localized: "Copy Path"), symbol: "doc.on.doc", action: .copy(repository.root.path)))
        return menu
    }

    /// The name, the facts, then the open pull requests, one per line.
    static func toolTip(_ repository: MenuPanelState.Repository) -> String {
        let facts = facts(repository).joined(separator: " · ")
        let checks = repository.checks.map { String(localized: "Checks: \($0.state.panelStateText)") }
        let pullRequests = repository.pullRequests.prefix(8).map { "#\($0.number) \($0.title)" }
        return ([repository.name, facts, checks].compactMap { $0 }.filter { !$0.isEmpty } + pullRequests).joined(
            separator: "\n")
    }

    /// Branch with ahead/behind, modified files, pull requests and agents; an error replaces them all.
    static func facts(_ repository: MenuPanelState.Repository) -> [String] {
        if let error = repository.error { return [error] }
        var facts: [String] = []
        if let branch = repository.branch {
            var text = branch
            if repository.ahead > 0 { text += " ↑\(repository.ahead)" }
            if repository.behind > 0 { text += " ↓\(repository.behind)" }
            facts.append(text)
        }
        if repository.changedFiles > 0 { facts.append(String(localized: "\(repository.changedFiles) modified")) }
        if let pullRequests = pullRequestFact(repository) { facts.append(pullRequests) }
        if let agents = agentFact(repository.agents) { facts.append(agents) }
        return facts
    }

    private static func pullRequestFact(_ repository: MenuPanelState.Repository) -> String? {
        let reviews = repository.pullRequests.filter(\.reviewRequested).count
        if reviews > 0 { return String(localized: "\(reviews) to review") }
        if !repository.pullRequests.isEmpty { return String(localized: "\(repository.pullRequests.count) open PRs") }
        return nil
    }

    /// The most urgent agent state present, counted.
    private static func agentFact(_ agents: AgentSummary) -> String? {
        if agents.needsInput > 0 { return String(localized: "\(agents.needsInput) needs input") }
        if agents.working > 0 { return String(localized: "\(agents.working) working") }
        if agents.done > 0 { return String(localized: "\(agents.done) done") }
        return nil
    }

    /// A repository's agents as one mark: the most urgent agent's, turning while any of them works.
    static func agentMark(_ repository: MenuPanelState.Repository, sessions: [AgentSession]) -> AgentMarkState? {
        let key = ProviderActivity.key(repository.root)
        let here = sessions.filter { ProviderActivity.key(home($0)) == key }
        guard
            let lead = here.filter({ !$0.isSubagent }).min(by: { $0.state < $1.state })
                ?? here.min(by: { $0.state < $1.state })
        else { return nil }
        return AgentMarkState(tool: lead.tool, state: here.contains { $0.state == .working } ? .working : lead.state)
    }
}
