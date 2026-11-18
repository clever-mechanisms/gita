import AppKit
import GitaCore

/// Rows about live production in the Commit tab: its domains and pin state, its errors, alerts and Agent Runs,
/// Vercel's own incidents, a rolling release, and what production serves when it is another commit.
@MainActor
enum ProductionRows {
    private static let alertLimit = 3
    private static let rowIcon: CGFloat = 11
    private static let triangleIcon: CGFloat = 10
    private static let shortSHA = 7

    /// Live production whose deployment is not among this commit's listed ones (pinned to an older build).
    static func liveBlock(_ production: VercelContext.Production, context: CommitDetailContext) -> NSView {
        let head = Deck.hstack(
            [
                Deck.icon("triangle.fill", size: triangleIcon, color: Theme.success),
                Deck.label(String(localized: "Live in production"), font: Theme.bodyEmphasis), Deck.spacer(),
            ], spacing: 8)
        let view = DetailRows.block([head] + domainRows(production, context: context))
        view.setAccessibilityLabel(String(localized: "Live in production"))
        return view
    }

    /// The production domain (unless the block's address already is it), the pin state and the live signals.
    static func domainRows(
        _ production: VercelContext.Production, context: CommitDetailContext, showsDomain: Bool = true
    ) -> [NSView] {
        var rows: [NSView] = []
        if showsDomain, let domain = production.primaryDomain {
            let address = DetailRows.address(domain.host ?? domain.absoluteString)
            address.toolTip = production.domains.compactMap(\.host).joined(separator: "\n")
            let more = production.domains.count > 1 ? Deck.caption("+\(production.domains.count - 1)") : nil
            rows.append(
                Deck.hstack(
                    [address, more, Deck.spacer(), DetailRows.copyLink(domain), DetailRows.openLink(domain)]
                        .compactMap { $0 }, spacing: 8))
        }
        if production.isPinned {
            let newer =
                production.latestCommit.map {
                    String(localized: "Pinned · newer production build \(String($0.prefix(shortSHA))) is not live")
                } ?? String(localized: "Pinned · a newer production build is not live")
            rows.append(Deck.label(newer, font: Theme.caption, color: Theme.needsInputText))
        }
        return rows + liveSignalRows(production, context: context)
    }

    /// Under live production: errors of its deployment, unresolved alerts, Vercel's incidents and eve Agent Runs.
    static func liveSignalRows(_ production: VercelContext.Production, context: CommitDetailContext) -> [NSView] {
        guard let signals = context.input.vercelSignals else { return [] }
        let dashboard = context.input.vercelDashboard
        var rows: [NSView] = []
        if let errors = signals.errors, errors.deploymentID == production.deploymentID {
            // The deployment's own Logs link sits right above: no second one.
            rows.append(
                DetailRows.signalRow(
                    errors.hasErrors ? "exclamationmark.triangle" : "checkmark.circle", VercelSignalText.errors(errors),
                    color: errors.hasErrors ? Theme.needsInputText : Theme.secondaryText))
        }
        rows += signals.activeAlerts.prefix(alertLimit).map { alertRow($0, dashboard: dashboard) }
        if let platform = signals.platform, platform.isDegraded { rows.append(platformRow(platform)) }
        if let runs = signals.agentRuns {
            rows.append(
                DetailRows.signalRow(
                    "sparkles", "eve · " + VercelSignalText.runs(runs),
                    color: runs.failed > 0 ? Theme.needsInputText : Theme.secondaryText,
                    link: dashboard.map {
                        (String(localized: "Agent Runs ↗"), $0.appendingPathComponent("observability/agent-runs"))
                    }))
        }
        return rows
    }

    private static func alertRow(_ alert: VercelSignals.Alert, dashboard: URL?) -> NSView {
        let text = [
            alert.title ?? VercelSignalText.alertType(alert.type), alert.startedAt.map { DeckFormat.relative($0) },
        ]
        .compactMap { $0 }.joined(separator: " · ")
        let url = alert.url ?? dashboard?.appendingPathComponent("observability")
        return DetailRows.signalRow(
            "bell.badge", text, color: Theme.failure, link: url.map { (String(localized: "Open ↗"), $0) })
    }

    /// Vercel's own incident: under live production and on a failed build, where it may be the cause.
    static func platformRow(_ platform: VercelSignals.Platform) -> NSView {
        DetailRows.signalRow(
            "exclamationmark.triangle", "Vercel · " + VercelSignalText.platform(platform), color: Theme.needsInputText,
            link: (platform.incidents.first?.url ?? platform.pageURL).map { (String(localized: "Status ↗"), $0) })
    }

    /// On the canary of an active rolling release: its stage and the steps that move it on.
    static func rolloutRows(_ rollout: VercelSignals.Rollout, context: CommitDetailContext) -> [NSView] {
        let text = VercelSignalText.rollout(rollout)
        let label = Deck.label(
            text, font: Theme.body,
            color: rollout.nextStageNeedsApproval || rollout.isPaused ? Theme.needsInputText : Theme.running)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var rows: [NSView] = [
            Deck.hstack(
                [Deck.icon("chart.bar.xaxis", size: rowIcon, color: Theme.running), label, Deck.spacer()], spacing: 6)
        ]
        let actions = VercelActionService.RolloutAction.allCases.filter {
            VercelActionService.isOffered($0, rollout: rollout)
        }
        if !actions.isEmpty, let perform = context.rolloutAction {
            let buttons: [NSView] = actions.map { action in
                PartsButton.quiet(
                    VercelSignalText.rolloutShortTitle(action), symbol: VercelSignalText.rolloutSymbol(action)
                ) { perform(action) }
            }
            rows.append(Deck.hstack(buttons + [Deck.spacer()], spacing: 6))
        }
        return rows
    }

    /// On every other commit: what production serves and how far the production branch has moved past it.
    static func productionServes(_ production: VercelContext.Production, context: CommitDetailContext) -> NSView {
        let text = servesText(
            production, behind: context.input.productionBehind, branch: context.input.productionBranch)
        let label = Deck.label(text, font: Theme.body, color: Theme.secondaryText)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [
            Deck.icon("triangle.fill", size: triangleIcon, color: Theme.success), label, Deck.spacer(),
        ]
        if let commit = production.commit, let select = context.selectCommit {
            views.append(PartsButton.link(String(localized: "Show")) { select(commit) })
        }
        if let domain = production.primaryDomain ?? production.url { views.append(DetailRows.openLink(domain)) }
        let view = DetailRows.paddedRow(views)
        view.setAccessibilityLabel(text)
        return view
    }

    static func servesText(_ production: VercelContext.Production, behind: Int?, branch: String?) -> String {
        let sha = production.commit.map { String($0.prefix(shortSHA)) } ?? ""
        var text = String(localized: "Production serves \(sha)")
        if let behind, let branch {
            text +=
                " · "
                + (behind == 0
                    ? String(localized: "up to date with \(branch)") : String(localized: "\(behind) behind \(branch)"))
        }
        return text
    }

    /// The newest production deployment when it is not from this commit.
    static func productionElsewhere(_ item: ProviderItem) -> NSView {
        let name = Deck.label(
            [HistoryChips.environmentName(item), item.branch].compactMap { $0 }.joined(separator: " · "),
            font: Theme.body, color: Theme.secondaryText)
        var views: [NSView] = [
            Deck.icon("triangle.fill", size: triangleIcon, color: Theme.tertiaryText), name, Deck.spacer(),
            Deck.caption(String(localized: "not from this commit")),
        ]
        if let url = Deck.safeWebURL(item.url) { views.append(DetailRows.openLink(url)) }
        return DetailRows.paddedRow(views)
    }
}
