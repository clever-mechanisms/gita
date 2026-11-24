import AppKit
import GitaCore

/// The worktree strip's single-line chips: Remote update (if moved) · Agent · Pull request · Checks · Deployment.
/// Idle or unlinked surfaces return nil instead of repeating "None" / "Not linked".
@MainActor
enum WorktreeStripCells {
    private static let shortSHA = 7
    /// The worst check state wins the chip, in this order.
    private static let checkPriority: [SignalState] = [.failure, .running, .pending, .cancelled, .neutral, .success]

    static func cells(
        _ input: WorktreeStripView.Input, now: Date = Date(), narrow: Bool = false
    ) -> [StripCellContent] {
        [
            remoteUpdate(input),
            input.shown.contains(.agent) ? agent(input, now: now) : nil,
            input.shown.contains(.pullRequest) ? pullRequest(input) : nil,
            input.shown.contains(.checks) ? checks(input) : nil,
            input.shown.contains(.deployment) ? deployment(input, narrow: narrow) : nil,
        ].compactMap { $0 }
    }

    static func remoteUpdate(_ input: WorktreeStripView.Input) -> StripCellContent? {
        guard let update = input.remoteUpdate else { return nil }
        return StripCellContent(
            icon: .symbol("arrow.down.to.line.compact", color: Theme.needsInputText),
            caption: update.summary,
            value: String(localized: "Fetch now"),
            valueFont: Theme.bodyEmphasis,
            valueColor: Theme.needsInputText,
            spoken: String(localized: "\(update.summary), fetch now"),
            toolTip: update.toolTip,
            click: .fetch)
    }

    static func agent(_ input: WorktreeStripView.Input, now: Date = Date()) -> StripCellContent? {
        guard let session = input.session else { return nil }
        let toolName = WindowAgents.title(session)
        let isCrowd = input.otherAgents > 0 || input.subagents > 0
        let attention = session.state == .needsInput
        let value =
            isCrowd
            ? WindowAgents.crowdLine(
                WindowAgents.Crowd(
                    lead: session, others: input.otherAgents, subagents: input.subagents, state: session.state),
                naming: false)
            : WindowAgents.stateTitle(session.state)
        let detail: String
        let toolTip: String
        let click: StripCellContent.Click
        if isCrowd {
            detail = agentCrowdDetail(otherAgents: input.otherAgents, subagents: input.subagents)
            toolTip = String(localized: "Worktrees & Agents")
            click = .agent(nil)
        } else {
            detail =
                attention
                ? String(localized: "Show ›")
                : (session.startedAt.map { DeckFormat.duration(now.timeIntervalSince($0)) } ?? "")
            toolTip = WindowAgents.shared.revealTitle(session)
            click = .agent(session)
        }
        return StripCellContent(
            icon: .agent(AgentMarkState(session), name: session.tool.displayName),
            caption: toolName,
            value: value,
            valueColor: attention ? Theme.needsInputText : Theme.text,
            detail: detail,
            detailColor: attention ? Theme.needsInputText : Theme.secondaryText,
            spoken: agentSpoken(toolName: toolName, state: session.state, isCrowd: isCrowd),
            toolTip: toolTip,
            isAttention: attention,
            click: click)
    }

    private static func agentCrowdDetail(otherAgents: Int, subagents: Int) -> String {
        var parts: [String] = []
        if otherAgents > 0 { parts.append(String(localized: "\(otherAgents + 1) agents")) }
        if subagents > 0 { parts.append(String(localized: "\(subagents) subagents")) }
        return parts.joined(separator: " · ")
    }

    private static func agentSpoken(toolName: String, state: AgentState, isCrowd: Bool) -> String {
        if isCrowd {
            return state == .needsInput
                ? String(localized: "Agent needs input, open Worktrees and Agents")
                : String(localized: "\(toolName) and other agents are active, open Worktrees and Agents")
        }
        switch state {
        case .needsInput: return String(localized: "\(toolName) needs input, show terminal")
        case .working: return String(localized: "\(toolName) is working, show terminal")
        case .done: return String(localized: "\(toolName) finished, show terminal")
        case .idle: return String(localized: "\(toolName) is idle, show terminal")
        }
    }

    static func pullRequest(_ input: WorktreeStripView.Input) -> StripCellContent? {
        guard let item = input.pullRequest, let pr = item.pullRequest else {
            guard input.canCreatePullRequest else { return nil }
            return StripCellContent(
                icon: .symbol("plus", color: Theme.secondaryText),
                value: String(localized: "Create PR…"),
                valueFont: Theme.body,
                valueColor: Theme.secondaryText,
                spoken: String(localized: "Create a pull request for this branch in browser"),
                toolTip: String(
                    localized: "Opens GitHub in your browser, with the account the browser is signed in to."),
                isGhost: true,
                click: .createPullRequest)
        }
        let title = item.title.replacingOccurrences(of: "#\(pr.number) ", with: "")
        let status = HistoryChips.pullRequestLabel(pr)
        let changesRequested = pr.status?.review == .changesRequested
        return StripCellContent(
            icon: .symbol(pr.lifecycle == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull", color: Theme.text),
            caption: "#\(pr.number)",
            value: title,
            valueFont: Theme.body,
            detail: status,
            detailColor: HistoryChips.pullRequestColor(pr),
            spoken: String(localized: "Pull request #\(pr.number), \(title), \(status), open in browser"),
            toolTip: item.url?.absoluteString,
            isAttention: changesRequested,
            click: item.url.map { .open($0) } ?? .none)
    }

    static func checks(_ input: WorktreeStripView.Input) -> StripCellContent? {
        let checks = input.checks
        guard let first = checks.first else { return nil }
        let worst = checkPriority.first { state in checks.contains { $0.state == state } } ?? .neutral
        let lead = checks.first { $0.state == worst } ?? first
        let passed = checks.filter { $0.state == .success }.count
        let leadName = checkName(lead)
        let detail = worst == .failure ? leadName : (input.head.map { String($0.prefix(shortSHA)) } ?? "")
        let failing = worst == .failure
        return StripCellContent(
            caption: String(localized: "CI"),
            value: "\(passed)/\(checks.count)",
            valueColor: failing ? Theme.failure : Theme.text,
            symbol: Style.stateSymbol(worst),
            symbolColor: Theme.color(for: worst),
            detail: detail,
            detailColor: failing ? Theme.failure : Theme.secondaryText,
            spoken: String(localized: "Checks: \(passed) of \(checks.count) passed, \(leadName), show commit checks"),
            toolTip: checks.map { "\(checkName($0)) · \($0.localizedDetail)" }.joined(separator: "\n"),
            isAttention: failing,
            click: .checks)
    }

    private static func checkName(_ item: ProviderItem) -> String {
        item.kind == .deployment ? "Vercel" : item.category
    }

    static func deployment(_ input: WorktreeStripView.Input, narrow: Bool = false) -> StripCellContent? {
        if input.isProductionBranch, let production = input.production {
            return self.production(production, behind: input.productionBehind ?? 0, narrow: narrow)
        }
        guard let item = input.deployment else { return nil }
        let environment = HistoryChips.environmentName(item)
        let state = item.state == .success ? ProviderText.status("Ready") : item.state.localizedTitle
        let age = item.date.map { DeckFormat.relative($0) } ?? ""
        let comments = input.comments > 0 ? String(localized: "\(input.comments) comments") : nil
        // The branch URL always serves the branch's latest ready deployment: the one worth sharing.
        let url = Deck.safeWebURL(input.branchURL) ?? Deck.safeWebURL(item.url)
        let detail = [url?.host, age, comments].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let failing = item.state == .failure
        return StripCellContent(
            caption: narrow ? "" : environment,
            value: state,
            valueColor: failing ? Theme.failure : Theme.text,
            symbol: "triangle.fill",
            symbolColor: item.state == .success ? Theme.text : Theme.color(for: item.state),
            detail: narrow ? "" : detail,
            detailFont: Theme.mono,
            spoken: String(localized: "\(environment) deployment is \(state), open or copy URL"),
            toolTip: url?.absoluteString,
            actionURL: url,
            showsOpenAction: !narrow,
            isAttention: failing,
            click: url.map { .open($0) } ?? .none)
    }

    /// On the production branch the chip shows what production serves instead of the branch's preview.
    private static func production(
        _ production: VercelContext.Production, behind: Int, narrow: Bool
    ) -> StripCellContent {
        let domain = production.primaryDomain ?? production.url
        let color = behind > 0 ? Theme.needsInputText : Theme.text
        let stateText = behind > 0 ? String(localized: "\(behind) behind") : String(localized: "Live")
        let sha = production.commit.map { String($0.prefix(shortSHA)) }
        let detail = [domain?.host, sha].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let spoken =
            behind > 0
            ? String(localized: "Production is \(behind) commits behind, open deployment")
            : String(localized: "Production deployment is live, open in browser")
        return StripCellContent(
            caption: narrow ? "" : String(localized: "Production"),
            value: stateText,
            valueColor: color,
            symbol: "triangle.fill",
            symbolColor: behind > 0 ? Theme.needsInputText : Theme.success,
            detail: narrow ? "" : detail,
            detailFont: Theme.mono,
            spoken: spoken,
            toolTip: [
                production.isPinned ? String(localized: "Pinned to an older production build") : nil,
                domain?.absoluteString,
            ].compactMap { $0 }.joined(separator: "\n"),
            actionURL: domain,
            showsOpenAction: !narrow,
            isAttention: behind > 0,
            click: domain.map { .open($0) } ?? .none)
    }
}
