import GitaCore

/// Tab badge shown on the trailing edge of a repository tab.
enum TabBadge: Equatable {
    case none
    case needsInput
    case done
}

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
    var doneSeen = false
    var color: TabColor?
    var shortcut: Int?

    /// Working and idle use the mark alone (turning or dimmed); Needs input and Done render capsules.
    var badge: TabBadge {
        switch agent {
        case .needsInput: .needsInput
        case .done: .done
        case .working, .idle, nil: .none
        }
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
            name, color?.localizedTitle, branch.isEmpty ? nil : branch, tool?.displayName,
            agent.map(WindowAgents.stateTitle),
            silenced ? Self.silencedTitle : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    static var silencedTitle: String { String(localized: "Notifications silenced") }
    var closeTitle: String { String(localized: "Close \(name)") }
}
