import AppKit
import GitaCore

/// The scenes of what GitHub, Vercel and the agents add: the history's Status column, and agent sessions.
extension SetupScenes {
    // MARK: The Status column, as in the window

    /// What a chip is about; each kind leaves the picture with its integration. In order of what a narrow picture
    /// keeps first.
    enum ChipKind: Int, Comparable {
        case checks, preview, pullRequest, live

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A chip and the step its state arrived at (it fades in during that step; -1 is there from the start).
    struct Chip {
        var kind: ChipKind
        var title: String
        var color: NSColor
        var image: NSImage?
        var since: Int
    }

    /// The chips of the sample history's `row` at `step`. The branch in progress runs its checks while its preview
    /// builds, both finish, then its review comes in; the commit before it failed its checks; the merged pull
    /// request serves production. GitHub brings pull requests and checks, Vercel previews and production.
    static func statusChips(row: Int, step: Int, choices: SetupChoices) -> [Chip] {
        let chips: [Chip]
        switch row {
        case 0: chips = branchTipChips(step: step)
        case 1: chips = [checksChip(.failure, since: -1)]
        case 2:
            chips = [
                Chip(
                    kind: .pullRequest, title: String(localized: "#\(22) merged"), color: Theme.merged,
                    image: BrandMarks.image(.github, size: 11), since: -1),
                Chip(
                    kind: .live, title: String(localized: "Live"), color: Theme.success,
                    image: BrandMarks.image(.vercel, size: 9), since: -1),
            ]
        case 5: chips = [checksChip(.success, since: -1)]
        default: chips = []
        }
        return chips.filter { shows($0.kind, choices) }
    }

    private static func branchTipChips(step: Int) -> [Chip] {
        let finished = step >= 1
        let approved = step >= 2
        let review =
            approved ? PullRequestStatusLabel.Review.approved.localizedTitle : String(localized: "Review requested")
        let state: SignalState = finished ? .success : .running
        let preview = String(localized: "Preview")
        return [
            Chip(
                kind: .pullRequest, title: String(localized: "#\(24) \(review)"),
                color: approved ? Theme.success : Theme.needsInputText, image: BrandMarks.image(.github, size: 11),
                since: approved ? 2 : 0),
            checksChip(state, since: finished ? 1 : 0),
            Chip(
                kind: .preview,
                title: finished ? String(localized: "\(preview) ready") : String(localized: "\(preview) building"),
                color: Theme.color(for: state), image: BrandMarks.image(.vercel, size: 9), since: finished ? 1 : 0),
        ]
    }

    private static func checksChip(_ state: SignalState, since: Int) -> Chip {
        let settled = state != .running
        return Chip(
            kind: .checks, title: HistoryChips.checksChipLabel(state), color: Theme.color(for: state),
            image: Deck.symbol(
                Style.stateSymbol(state), size: 10, weight: settled ? .bold : .semibold, color: Theme.color(for: state),
                inner: settled ? .white : nil),
            since: since)
    }

    private static func shows(_ kind: ChipKind, _ choices: SetupChoices) -> Bool {
        switch kind {
        case .pullRequest, .checks: choices[.useGitHub]
        case .preview, .live: choices[.useVercel]
        }
    }

    /// The sample history with its Status column. Across the page it has its column titles and every chip; in a
    /// card (`compact`) it shows the top rows and the chips that fit, the checks first.
    static func drawStatus(_ frame: Frame, compact: Bool) {
        let rect = frame.rect
        let header: CGFloat = compact ? 0 : 22
        let rows = sampleHistory.count
        let rowHeight = compact ? 28 : min(27, (rect.height - header) / CGFloat(rows))
        let graph = NSRect(x: rect.minX, y: rect.minY + header, width: rect.width, height: rect.height - header)
        let textX = laneX(2, in: rect) + 8
        let statusX = compact ? rect.maxX - 146 : max(textX + 230, rect.maxX - widestChips(frame.choices))
        if !compact {
            for (title, x) in [(String(localized: "History"), textX), (String(localized: "Status"), statusX)] {
                text(title, at: NSPoint(x: x, y: rect.minY), font: Theme.caption, color: Theme.secondaryText)
            }
            Theme.separator.setFill()
            NSRect(x: rect.minX, y: rect.minY + header - 5, width: rect.width, height: 1).fill()
        }
        sampleGraph(in: graph, rowHeight: rowHeight, subjectsEnd: statusX - 12)
        for row in 0..<rows {
            var chips = statusChips(row: row, step: frame.step, choices: frame.choices)
            if compact { chips.sort { $0.kind < $1.kind } }
            let y = graph.minY + rowHeight * (CGFloat(row) + 0.5) - 9
            guard y + 18 <= rect.maxY else { break }
            drawChips(chips, x: statusX, y: y, limit: rect.maxX, frame: frame)
        }
        if !compact && !frame.choices[.useGitHub] && !frame.choices[.useVercel] {
            text(
                String(localized: "GitHub and Vercel are off: the history stays as it is."),
                at: NSPoint(x: statusX, y: graph.minY + rowHeight / 2 - 8), font: Theme.caption,
                color: Theme.secondaryText, width: rect.maxX - statusX)
        }
    }

    private static let chipGap: CGFloat = 6

    /// The widest row of chips at any step, so the Status column holds still while the states change.
    private static func widestChips(_ choices: SetupChoices) -> CGFloat {
        var widest: CGFloat = 0
        for step in 0..<SetupScene.status.steps {
            for row in sampleHistory.indices {
                let chips = statusChips(row: row, step: step, choices: choices)
                widest = max(widest, chips.reduce(0) { $0 + pillWidth($1.title, image: $1.image != nil) + chipGap })
            }
        }
        return widest
    }

    /// The chips from `start`, as many as end before `limit`.
    private static func drawChips(_ chips: [Chip], x start: CGFloat, y: CGFloat, limit: CGFloat, frame: Frame) {
        var x = start
        for chip in chips {
            guard x + pillWidth(chip.title, image: chip.image != nil) <= limit else { return }
            let alpha = chip.since == frame.step ? frame.progress : 1
            x += pill(chip.title, at: NSPoint(x: x, y: y), color: chip.color, image: chip.image, alpha: alpha) + chipGap
        }
    }

    // MARK: Agents: sessions next to their branch, changing state

    static let sceneAgents: [(tool: AgentTool, task: String, branch: String)] = [
        (.claudeCode, String(localized: "Polish repository navigation"), "feature/navigation"),
        (.codex, String(localized: "Write the tab tests"), "feature/tabs"),
        (.gemini, String(localized: "Review the sidebar"), "review/sidebar"),
    ]
    private static let agentStates: [AgentState] = [.working, .needsInput, .done]

    /// A row's state at `step`: each one moves on every step, so the three states always show.
    static func agentState(row: Int, step: Int) -> AgentState { agentStates[(row + step) % agentStates.count] }

    /// One row per session: the agent's mark, its task (only its name in a narrow card), the branch and its state.
    static func drawAgents(_ frame: Frame) {
        let rect = frame.rect
        let narrow = rect.width < 420
        let rowHeight = min(44, rect.height / CGFloat(sceneAgents.count))
        for (index, agent) in sceneAgents.enumerated() {
            let top = rect.minY + CGFloat(index) * rowHeight
            let on = frame.choices[.useAgents] && frame.choices[agent.tool.detectionPreference]
            let alpha: CGFloat = on ? 1 : 0.35
            let state = agentState(row: index, step: frame.step)
            let title = on ? WindowAgents.stateTitle(state) : String(localized: "Off")
            let pillX = rect.maxX - pillWidth(title, image: false)
            AgentMarks.draw(agent.tool, in: NSRect(x: rect.minX + 2, y: top + 4, width: 22, height: 22), flipped: true)
            text(
                narrow ? agent.tool.displayName : "\(agent.tool.displayName) · \(agent.task)",
                at: NSPoint(x: rect.minX + 34, y: top + 2), font: Theme.bodyEmphasis, color: Theme.text, alpha: alpha,
                width: pillX - rect.minX - 42)
            text(
                agent.branch, at: NSPoint(x: rect.minX + 34, y: top + 19), font: Theme.mono,
                color: Theme.secondaryText, alpha: alpha, width: pillX - rect.minX - 42)
            pill(
                title, at: NSPoint(x: pillX, y: top + 6), color: on ? WindowAgents.stateColor(state) : Theme.idle,
                alpha: on ? max(0.25, frame.progress) : 0.6)
        }
    }
}
