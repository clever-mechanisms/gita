import AppKit
import GitaCore

/// The worktree strip's five cells for an input: Agent · Branch · Pull request · Checks · Preview deployment.
@MainActor
enum WorktreeStripCells {
    private static let shortSHA = 7
    /// The worst check state wins the cell, in this order.
    private static let checkPriority: [SignalState] = [.failure, .running, .pending, .cancelled, .neutral, .success]

    static func cells(_ input: WorktreeStripView.Input, now: Date = Date()) -> [StripCellContent] {
        [agent(input, now: now), branch(input), pullRequest(input), checks(input), deployment(input)]
    }

    static func agent(_ input: WorktreeStripView.Input, now: Date = Date()) -> StripCellContent {
        guard let session = input.session else {
            return StripCellContent(
                icon: .symbol("apple.terminal"), caption: String(localized: "Agent"), value: String(localized: "None"),
                valueColor: Theme.secondaryText, toolTip: String(localized: "Worktrees & Agents"), click: .agent(nil))
        }
        // The tile shows the agent's mark, turning while it works; the value says its state.
        var cell = StripCellContent(
            icon: .agent(AgentMarkState(session), name: session.tool.displayName), caption: String(localized: "Agent"),
            value: session.isSubagent ? WindowAgents.line(session) : WindowAgents.stateTitle(session.state),
            valueFont: Theme.bodyEmphasis, spoken: WindowAgents.line(session))
        if input.otherAgents > 0 || input.subagents > 0 {
            // Several agents share this checkout: say so, and open the overview that lists each of them.
            var detail: [String] = []
            if input.otherAgents > 0 { detail.append(String(localized: "\(input.otherAgents + 1) agents")) }
            if input.subagents > 0 { detail.append(String(localized: "\(input.subagents) subagents")) }
            cell.detail = detail.joined(separator: " · ")
            cell.toolTip = String(localized: "Worktrees & Agents")
            cell.click = .agent(nil)
        } else {
            let started = session.startedAt.map {
                String(localized: "Session \(DeckFormat.duration(now.timeIntervalSince($0)))")
            }
            cell.detail = [started, String(localized: "this checkout")].compactMap { $0 }.joined(separator: " · ")
            cell.toolTip = WindowAgents.shared.revealTitle(session)
            cell.click = .agent(session)
        }
        return cell
    }

    static func branch(_ input: WorktreeStripView.Input) -> StripCellContent {
        var detail = ""
        var color = Theme.secondaryText
        if input.ahead > 0 {
            detail = String(localized: "↑\(input.ahead) not pushed")
            color = Theme.accentText
            if input.behind > 0 { detail += " · ↓\(input.behind)" }
        } else if input.behind > 0 {
            detail = String(localized: "↓\(input.behind) behind")
        } else if !input.hasUpstream {
            detail = String(localized: "No upstream")
        } else if input.branch != nil {
            detail = String(localized: "Up to date")
        }
        return StripCellContent(
            caption: String(localized: "Branch"), value: input.branch ?? String(localized: "Detached"),
            valueFont: Theme.bodyEmphasis, valueColor: Theme.checkedOut, detail: detail, detailColor: color,
            toolTip: String(localized: "Switch Branch…"), click: .branch)
    }

    static func pullRequest(_ input: WorktreeStripView.Input) -> StripCellContent {
        guard let item = input.pullRequest, let pr = item.pullRequest else {
            return StripCellContent(
                caption: String(localized: "Pull request"), value: String(localized: "None"),
                valueColor: Theme.secondaryText,
                toolTip: input.canCreatePullRequest
                    ? String(localized: "Opens GitHub in your browser, with the account the browser is signed in to.")
                    : Section.pullRequests.localizedTitle,
                link: input.canCreatePullRequest ? String(localized: "Create PR…") : nil,
                click: input.canCreatePullRequest ? .createPullRequest : .page(.pullRequests))
        }
        return StripCellContent(
            caption: String(localized: "Pull request"),
            value: "#\(pr.number) \(item.title.replacingOccurrences(of: "#\(pr.number) ", with: ""))",
            detail: HistoryChips.pullRequestLabel(pr), detailColor: HistoryChips.pullRequestColor(pr),
            toolTip: item.url?.absoluteString, click: item.url.map { .open($0) } ?? .none)
    }

    static func checks(_ input: WorktreeStripView.Input) -> StripCellContent {
        let checks = input.checks
        guard let first = checks.first else {
            return StripCellContent(
                caption: String(localized: "Checks"), value: String(localized: "None"), valueColor: Theme.secondaryText,
                toolTip: Section.workflows.localizedTitle, click: .page(.workflows))
        }
        let worst = checkPriority.first { state in checks.contains { $0.state == state } } ?? .neutral
        let lead = checks.first { $0.state == worst } ?? first
        let passed = checks.filter { $0.state == .success }.count
        let head = input.head.map { String($0.prefix(shortSHA)) }
        return StripCellContent(
            caption: String(localized: "Checks"), value: checkName(lead), symbol: Style.stateSymbol(worst),
            symbolColor: Theme.color(for: worst),
            detail: [head, "\(passed)/\(checks.count)"].compactMap { $0 }.joined(separator: " · "),
            toolTip: checks.map { "\(checkName($0)) · \($0.localizedDetail)" }.joined(separator: "\n"),
            click: .checks)
    }

    private static func checkName(_ item: ProviderItem) -> String {
        item.kind == .deployment ? "Vercel" : item.category
    }

    static func deployment(_ input: WorktreeStripView.Input) -> StripCellContent {
        if input.isProductionBranch, let production = input.production {
            return self.production(production, behind: input.productionBehind ?? 0)
        }
        guard let item = input.deployment else {
            return StripCellContent(
                caption: String(localized: "Preview deployment"),
                value: input.deploymentStatus ?? String(localized: "None"), valueColor: Theme.secondaryText,
                toolTip: Section.deployments.localizedTitle, click: .page(.deployments))
        }
        let environment = HistoryChips.environmentName(item)
        let state = item.state == .success ? ProviderText.status("Ready") : item.state.localizedTitle
        let age = item.date.map { DeckFormat.relative($0) } ?? ""
        let comments = input.comments > 0 ? String(localized: "\(input.comments) comments") : nil
        // The branch URL always serves the branch's latest ready deployment: the one worth sharing.
        let url = Deck.safeWebURL(input.branchURL) ?? Deck.safeWebURL(item.url)
        return StripCellContent(
            caption: String(localized: "\(environment) deployment"), value: state, valueFont: Theme.bodyEmphasis,
            symbol: "triangle.fill", symbolColor: item.state == .success ? Theme.text : Theme.color(for: item.state),
            trailing: [age, comments].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            detail: url?.host ?? "", detailFont: Theme.mono, toolTip: url?.absoluteString, actionURL: url,
            click: url.map { .open($0) } ?? .none)
    }

    /// On the production branch the cell shows what production serves instead of the branch's preview.
    private static func production(_ production: VercelContext.Production, behind: Int) -> StripCellContent {
        let domain = production.primaryDomain ?? production.url
        let color = behind > 0 ? Theme.needsInputText : Theme.text
        return StripCellContent(
            caption: String(localized: "Production"),
            value: behind > 0 ? String(localized: "\(behind) behind") : String(localized: "Live"),
            valueFont: Theme.bodyEmphasis, valueColor: color, symbol: "triangle.fill",
            symbolColor: behind > 0 ? Theme.needsInputText : Theme.success,
            trailing: production.commit.map { String($0.prefix(shortSHA)) } ?? "", detail: domain?.host ?? "",
            detailFont: Theme.mono,
            toolTip: [
                production.isPinned ? String(localized: "Pinned to an older production build") : nil,
                domain?.absoluteString,
            ].compactMap { $0 }.joined(separator: "\n"), actionURL: domain, click: domain.map { .open($0) } ?? .none)
    }
}
