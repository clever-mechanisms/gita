import GitaCore

/// What one tab shows.
struct RepositoryTabState: Equatable {
    var name: String
    var branch = ""
    var path: String?
    /// The tab shows a linked worktree: the worktree symbol sits at its right end.
    var isWorktree = false
    /// Its repository's notifications are silenced from the tab's menu: a crossed-out bell sits at its right end.
    var silenced = false
    var agent: AgentState?
    var tool: AgentTool?
    var selected = false
    var busy = false
    var color: TabColor?
    var shortcut: Int?

    /// Working and idle are told by the mark (turning, or dimmed); waiting and done still need the word, and so does
    /// any state without a known tool.
    @MainActor var spelledState: String {
        let spelled = agent == .needsInput || agent == .done || (tool == nil && agent != nil)
        return spelled ? agent.map(WindowAgents.stateTitle) ?? "" : ""
    }
    /// The name first: an author tab's ("project [Author]") is often cut short.
    @MainActor var toolTip: String {
        let state = agent.map(WindowAgents.stateTitle)
        return [
            name, path, branch.isEmpty ? nil : branch,
            [tool?.displayName, state].compactMap { $0 }.joined(separator: " · "),
            silenced ? Self.silencedTitle : nil, shortcut.map { "⌘\($0)" },
        ].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
    }
    @MainActor var accessibilityLabel: String {
        [
            name, branch.isEmpty ? nil : branch, tool?.displayName, agent.map(WindowAgents.stateTitle),
            silenced ? Self.silencedTitle : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
    static var silencedTitle: String { String(localized: "Notifications silenced") }
    var closeTitle: String { String(localized: "Close \(name)") }
}
