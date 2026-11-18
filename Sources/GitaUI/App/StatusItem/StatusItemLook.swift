import GitaCore

/// What the menu bar item shows: its icon and its tooltip (also its accessibility label).
struct StatusItemLook: Equatable {
    var icon: MenuIcon.Look
    var toolTip: String

    /// The dot is lit exactly while the panel's "Needs you" has an item (`attention`).
    init(agents: AgentSummary, attention: [PanelAttention.Item], showsCount: Bool, showsDot: Bool) {
        icon = MenuIcon.Look(
            count: showsCount && agents.working > 0 ? agents.working : nil, dot: showsDot && !attention.isEmpty)
        func count(_ matches: (PanelAttention.Item.Kind) -> Bool) -> Int { attention.filter { matches($0.kind) }.count }
        let waiting = count { if case .agentWaiting = $0 { true } else { false } }
        let reviews = count { $0 == .reviewRequested }
        var facts = ["Gitā"]
        if agents.working > 0 { facts.append(String(localized: "\(agents.working) agents working")) }
        if waiting > 0 { facts.append(String(localized: "\(waiting) needs input")) }
        if reviews > 0 { facts.append(String(localized: "\(reviews) to review")) }
        if count({ $0 == .conflicts }) > 0 {
            facts.append(String(localized: "Conflicts"))
        } else if count({ $0 == .checksFailed }) > 0 {
            facts.append(String(localized: "Checks failing"))
        }
        toolTip = facts.joined(separator: ", ")
    }
}
