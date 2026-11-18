import AppKit
import GitaCore

/// The Status column's chips for one commit, in order: "Not pushed", an open pull request, CI, deployment and
/// agents; newest provider facts first within each kind.
@MainActor
enum HistoryChips {
    struct Input {
        var items: [ProviderItem]
        var agents: [AgentSession]
        var notPushed: Bool
        /// Production serves this commit (`VercelContext`); `liveItem` is its listed deployment, when listed.
        var live: VercelContext.Production?
        var liveItem: ProviderItem?
        var errors: VercelSignals.Errors?
        var rollout: VercelSignals.Rollout?
    }
    /// The state a set of runs shows: the worst one present.
    private static let statePriority: [SignalState] = [.failure, .running, .pending, .cancelled, .neutral, .success]
    private static let vercel = HistoryChip.Icon.brand(.vercel)
    private static let agentTooltipLimit = 12

    static func make(_ input: Input) -> [HistoryChip] {
        let sorted = input.items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let pullRequest = sorted.first { $0.kind == .pullRequest }
        var chips: [HistoryChip] = []
        if input.notPushed { chips.append(notPushed()) }
        if let pullRequest, let chip = self.pullRequest(pullRequest) { chips.append(chip) }
        if let chip = checks(runs: sorted.filter { $0.kind == .workflowRun }, pullRequest: pullRequest) {
            chips.append(chip)
        }
        chips += deployments(sorted.filter { $0.kind == .deployment }, input: input)
        if let chip = agents(input.agents) { chips.append(chip) }
        return chips
    }

    private static func notPushed() -> HistoryChip {
        HistoryChip(
            label: String(localized: "Not pushed"), color: Theme.secondaryText, target: .none,
            tooltip: String(localized: "This commit is only on this Mac"))
    }

    /// An open, draft or closed pull request, by where it stands ("#24 Review requested"). A merged one is already
    /// told beside the graph (the merge flair: who merged, how many commits); here it would repeat itself on every
    /// commit the pull request brought in.
    static func pullRequest(_ item: ProviderItem) -> HistoryChip? {
        guard let pr = item.pullRequest, pr.lifecycle != .merged else { return nil }
        let chip = pullRequestChip(pr)
        return HistoryChip(
            label: chip.label, color: chip.color, target: .provider(item),
            tooltip: [item.title, pullRequestLabel(pr), item.localizedDetail].filter { !$0.isEmpty }.joined(
                separator: "\n"),
            icon: .brand(.github))
    }

    /// The commit's workflow runs (one per workflow, the newest), else the pull request's head checks.
    static func checks(runs allRuns: [ProviderItem], pullRequest: ProviderItem?) -> HistoryChip? {
        var seenWorkflows = Set<Int64>()
        let runs = allRuns.filter {
            guard let identity = $0.workflowDatabaseID, identity > 0 else { return true }
            return seenWorkflows.insert(identity).inserted
        }
        if let first = runs.first {
            let item = statePriority.lazy.compactMap { state in runs.first { $0.state == state } }.first ?? first
            let label = checksLabel(item.state, prefix: String(localized: "CI"))
            let lines = runs.map { "\($0.category) · \($0.localizedDetail)" }
            return HistoryChip(
                label: checksChipLabel(item.state), color: Theme.color(for: item.state), target: .provider(item),
                tooltip: ([label] + lines).joined(separator: "\n"), icon: .symbol(Style.stateSymbol(item.state)))
        }
        guard let item = pullRequest, let pr = item.pullRequest, let checks = pr.checksState else { return nil }
        let state = checks.state
        return HistoryChip(
            label: checksChipLabel(state), color: Theme.color(for: state), target: .provider(item),
            tooltip: String(localized: "PR #\(pr.number) head checks · \(checks.localizedTitle)"),
            icon: .symbol(Style.stateSymbol(state)))
    }

    /// Live production (and a preview beside it), else the canary of an active rolling release, else the newest
    /// production deployment or the newest deployment.
    static func deployments(_ deployments: [ProviderItem], input: Input) -> [HistoryChip] {
        if let live = input.live {
            let other = deployments.first { $0.deployment?.environment != .production }
            return [liveChip(live, item: input.liveItem, errors: input.errors)]
                + [other].compactMap { $0.map(deployment) }
        }
        if let rollout = input.rollout, rollout.isActive, let host = rollout.canaryHost?.lowercased(),
            let item = deployments.first(where: { $0.url?.host?.lowercased() == host })
        {
            return [
                HistoryChip(
                    label: VercelSignalText.rolloutChip(rollout), color: Theme.running, target: .provider(item),
                    tooltip: [VercelSignalText.rollout(rollout), item.url?.host].compactMap { $0 }.joined(
                        separator: "\n"),
                    spoken: VercelSignalText.rollout(rollout), icon: vercel)
            ]
        }
        let shown = deployments.first { $0.deployment?.environment == .production } ?? deployments.first
        return [shown].compactMap { $0.map(deployment) }
    }

    /// Server or logged errors in the last hour turn the chip amber and say how many.
    private static func liveChip(
        _ live: VercelContext.Production, item: ProviderItem?, errors: VercelSignals.Errors?
    ) -> HistoryChip {
        let target: HistoryChip.Target =
            item.map { .provider($0) } ?? live.primaryDomain.map { .url($0) } ?? live.url.map { .url($0) } ?? .none
        let failing = errors?.hasErrors == true
        let liveText = String(localized: "Live in production")
        return HistoryChip(
            label: VercelSignalText.liveLabel(errors), color: failing ? Theme.needsInputText : Theme.success,
            target: target,
            tooltip: [liveText, live.primaryDomain?.host, errors.map(VercelSignalText.errors)].compactMap { $0 }
                .joined(separator: "\n"),
            spoken: failing ? VercelSignalText.liveLabel(errors) : liveText, icon: vercel)
    }

    private static func deployment(_ item: ProviderItem) -> HistoryChip {
        HistoryChip(
            label: deploymentDescription(item), color: Theme.color(for: item.state), target: .provider(item),
            tooltip: [deploymentDescription(item), item.url?.host].compactMap { $0 }.joined(separator: "\n"),
            icon: vercel)
    }

    /// One chip however many agents sit on the commit: the lead's mark (turning while one works), "+N" for others,
    /// every agent named in the tooltip.
    static func agents(_ agents: [AgentSession]) -> HistoryChip? {
        guard let crowd = WindowAgents.crowd(agents) else { return nil }
        let session = crowd.lead
        var label = session.isSubagent ? String(localized: "Subagent") : ""
        if crowd.others > 0 { label += label.isEmpty ? "+\(crowd.others)" : " +\(crowd.others)" }
        let lines = agents.filter { !$0.isSubagent }.prefix(agentTooltipLimit).map { WindowAgents.menuLine($0) }
        let tooltip =
            (lines.isEmpty ? [WindowAgents.line(session)] : Array(lines))
            + (crowd.subagents > 0 ? [String(localized: "\(crowd.subagents) subagents")] : [])
        // The mark turns while any of them works; only a wait for input colours the words.
        let motion: AgentState = agents.contains { $0.state == .working } ? .working : crowd.state
        let spoken = ([WindowAgents.line(session)] + (crowd.others > 0 ? ["+\(crowd.others)"] : [])).joined(
            separator: " ")
        return HistoryChip(
            label: label, color: crowd.state == .needsInput ? Theme.needsInputText : Theme.secondaryText,
            target: .agent(session), tooltip: tooltip.joined(separator: "\n"), agentState: motion, spoken: spoken,
            icon: .agent(session.tool))
    }
}
