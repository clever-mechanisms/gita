import Foundation
import GitaCore

/// Agents: working, then done, one line each; the idle ones folded into one summary row. An agent that waits for
/// input is a "Needs you" card instead. Subagents working beside the agent that started them are counted on its
/// row, not listed one by one.
extension PanelRowBuilder {
    private static let idleID = "idle"
    private static let idleNamesShown = 3

    func agentRows() -> [PanelRow] {
        let sessions = state.sessions.filter {
            $0.state != .needsInput && !WindowAgents.folds($0, in: state.sessions)
        }
        let active = [AgentState.working, .done].flatMap { state in sessions.filter { $0.state == state } }
        let idle = sessions.filter { $0.state == .idle }
        guard !sessions.isEmpty else { return [] }
        return [header("agents", String(localized: "Agents"), count: active.count)] + active.map(agentRow)
            + (idle.isEmpty ? [] : idleRows(idle))
    }

    /// "Idle · app, site, +2", opening onto the idle agents.
    private func idleRows(_ idle: [AgentSession]) -> [PanelRow] {
        let isOpen = expanded.contains(Self.idleID)
        var names: [String] = []
        for session in idle {
            let name = name(for: Self.home(session))
            if !names.contains(name) { names.append(name) }
        }
        let hidden = names.count - Self.idleNamesShown
        let shown = names.prefix(Self.idleNamesShown).joined(separator: ", ") + (hidden > 0 ? ", +\(hidden)" : "")
        let summary = PanelRow(
            id: Self.idleID, kind: .summary, lead: .chevron(expanded: isOpen),
            title: String(localized: "Idle · \(shown)"), titleColor: .secondary, count: "\(idle.count)",
            disclosure: .init(isOpen: isOpen), action: .toggle(Self.idleID),
            label: String(localized: "Idle, \(idle.count): \(names.joined(separator: ", "))"))
        return [summary] + (isOpen ? idle.map(agentRow) : [])
    }

    /// Where a session works, as the panel shows it.
    private struct Place {
        let repositoryURL: URL
        let repository: MenuPanelState.Repository?
        let checkout: URL
        /// The session works in a linked worktree, not the repository's main checkout.
        let inWorktree: Bool
    }

    private func place(_ session: AgentSession) -> Place {
        let repositoryURL = Self.home(session)
        let key = ProviderActivity.key(repositoryURL)
        let checkout = session.checkoutRoot ?? session.workingDirectory
        return Place(
            repositoryURL: repositoryURL,
            repository: state.repositories.first { ProviderActivity.key($0.root) == key },
            checkout: checkout, inWorktree: ProviderActivity.key(checkout) != key)
    }

    private func agentRow(_ session: AgentSession) -> PanelRow {
        let place = place(session)
        var title = name(for: place.repositoryURL)
        if place.inWorktree { title += " · " + place.checkout.lastPathComponent }
        var row = PanelRow(
            id: "agent:" + session.id, kind: .line, lead: .mark(AgentMarkState(session)), title: title,
            subtitle: facts(session, place).joined(separator: " · "), subtitleTool: session.tool,
            time: PanelTime.duration(since: session.stateSince, now: now), action: .reveal(session.id))
        row.chips = Self.chips(session, place)
        row.hoverChip = PanelChip(
            title: "", symbol: "macwindow", action: .showRepository(place.checkout),
            label: String(localized: "Show in Gitā"))
        row.label = [title, session.state.localizedTitle, row.subtitle, row.time].compactMap { $0 }.filter {
            !$0.isEmpty
        }.joined(separator: ", ")
        row.toolTip = checkoutFacts(session, place).joined(separator: " · ")
        return row
    }

    /// What the agent does, on its line: subagent, its task (else its branch), its subagents, and that it is done.
    /// The agent's mark leads the line, so its name is not repeated.
    private func facts(_ session: AgentSession, _ place: Place) -> [String] {
        var facts = session.isSubagent ? [String(localized: "Subagent")] : []
        if let task = session.title ?? Self.branchFact(session, place) { facts.append(task) }
        let subagents = WindowAgents.subagents(of: session, in: state.sessions)
        if !subagents.isEmpty { facts.append(String(localized: "\(subagents.count) subagents")) }
        if session.state == .done { facts.append(session.state.localizedTitle) }
        return facts
    }

    /// Where it works, in the tooltip: branch (with what is unpushed), modified files and a ready preview.
    private func checkoutFacts(_ session: AgentSession, _ place: Place) -> [String] {
        var facts = [Self.branchFact(session, place)].compactMap { $0 }
        guard !place.inWorktree, let repository = place.repository else { return facts }
        if repository.changedFiles > 0 { facts.append(String(localized: "\(repository.changedFiles) modified")) }
        if session.state == .working, repository.preview?.state == .success {
            facts.append(String(localized: "Preview ready"))
        }
        return facts
    }

    /// The branch, unless the worktree folder already names it; in the main checkout with its unpushed count.
    private static func branchFact(_ session: AgentSession, _ place: Place) -> String? {
        guard let branch = session.branch, !(place.inWorktree && place.checkout.lastPathComponent.hasPrefix(branch))
        else { return nil }
        if !place.inWorktree, let repository = place.repository, repository.branch == branch, repository.ahead > 0 {
            return branch + " ↑\(repository.ahead)"
        }
        return branch
    }

    /// Open the preview a working agent is building.
    private static func chips(_ session: AgentSession, _ place: Place) -> [PanelChip] {
        guard session.state == .working, !place.inWorktree, let preview = place.repository?.preview else { return [] }
        return [
            PanelChip(
                title: String(localized: "Open ↗"), style: .accent, action: .openURL(preview.url),
                label: String(localized: "Open Preview"))
        ]
    }
}
