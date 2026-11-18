import AppKit
import GitaCore

/// The words and colours agents are shown with.
extension WindowAgents {
    static func title(_ session: AgentSession) -> String {
        session.isSubagent ? String(localized: "Subagent") : session.tool.displayName
    }

    /// What a crowd line leads with.
    private enum CrowdShape {
        /// One agent and no subagents.
        case alone
        /// Someone in the crowd waits for input.
        case waiting
        /// One agent with subagents.
        case withSubagents
        /// Several top-level agents.
        case several
    }
    private static func shape(of crowd: Crowd) -> CrowdShape {
        if crowd.others == 0 && crowd.subagents == 0 { return .alone }
        if crowd.state == .needsInput { return .waiting }
        return crowd.others == 0 ? .withSubagents : .several
    }

    /// A checkout's agents in a sidebar-width line: "Claude Code · Working" alone, "Claude Code · 12 subagents" with
    /// subagents, "3 agents · 12 subagents" with several agents, "Needs input · 3 agents" when one of them waits.
    /// The words carry the most urgent state (the mark only turns while one works); the tooltip lists each agent.
    /// `naming: false` drops the agent's name where its mark stands beside the line ("Working · 12 subagents").
    static func crowdLine(_ crowd: Crowd, naming: Bool = true) -> String {
        let agents = String(localized: "\(crowd.others + 1) agents")
        let subagents = String(localized: "\(crowd.subagents) subagents")
        switch shape(of: crowd) {
        case .alone:
            return naming || crowd.lead.isSubagent ? line(crowd.lead) : stateLine(crowd.lead)
        case .waiting:
            return stateTitle(.needsInput) + " · " + (crowd.others > 0 ? agents : subagents)
        case .withSubagents:
            return (naming ? title(crowd.lead) : stateTitle(crowd.state)) + " · " + subagents
        case .several:
            return crowd.subagents > 0 ? agents + " · " + subagents : agents
        }
    }
    /// "Working 7 · Done 3 · Idle 2", most urgent first.
    static func stateCounts(_ sessions: [AgentSession]) -> String {
        let summary = AgentSummary(sessions)
        let counts: [(AgentState, Int)] = [
            (.needsInput, summary.needsInput), (.working, summary.working), (.done, summary.done),
            (.idle, summary.idle),
        ]
        return counts.filter { $0.1 > 0 }.map { String(localized: "\(stateTitle($0.0)) \($0.1)") }
            .joined(separator: " · ")
    }
    /// "Claude Code · Working · 2h" — tells apart agents whose state line reads the same.
    static func menuLine(_ session: AgentSession, now: Date = Date()) -> String {
        var text = line(session, now: now)
        if session.state != .idle, let started = session.startedAt {
            text += " · " + DeckFormat.duration(now.timeIntervalSince(started))
        }
        return text
    }
    static func stateTitle(_ state: AgentState) -> String {
        switch state {
        case .working: String(localized: "Working")
        case .needsInput: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        }
    }
    static func stateColor(_ state: AgentState) -> NSColor {
        switch state {
        case .working: Theme.accentText
        case .needsInput: Theme.needsInputText
        case .done: Theme.success
        case .idle: Theme.secondaryText
        }
    }
    /// "Claude Code · Working", "Claude Code · Idle 1d 17h".
    static func line(_ session: AgentSession, now: Date = Date()) -> String {
        "\(title(session)) · \(stateLine(session, now: now))"
    }
    /// "Working", "Idle 1d 17h": `line` without the name, beside the agent's mark (`AgentMarks`).
    static func stateLine(_ session: AgentSession, now: Date = Date()) -> String {
        guard session.state == .idle else { return stateTitle(session.state) }
        return String(localized: "Idle \(DeckFormat.duration(now.timeIntervalSince(session.stateSince)))")
    }
    /// Beside the mark: a subagent still says it is one ("Subagent · Done"); an agent says only its state.
    static func markedLine(_ session: AgentSession, now: Date = Date()) -> String {
        session.isSubagent ? line(session, now: now) : stateLine(session, now: now)
    }
}
