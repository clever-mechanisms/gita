import AppKit
import GitaCore

/// The three detail cards: pull request, workflow run and deployment, each a header and a grid of labelled rows.
extension ProviderDetailView {
    private typealias Row = (title: String, view: NSView)

    // MARK: Pull request card

    func showPullRequest(_ value: PullRequestDetail) {
        let summary = item.pullRequest
        if showsHeader {
            let merged = value.lifecycle == .merged
            let icon = Deck.icon(
                merged ? "arrow.triangle.merge" : "arrow.triangle.pull", size: 12,
                color: summary.map(HistoryChips.pullRequestColor) ?? Theme.success)
            addHeader(icon: icon, title: "#\(value.number) \(value.title)") { [item] in value.url ?? item.url }
        }
        var rows: [Row] = []
        if let opened = ProviderDetailFacts.openedBy(value, summary: summary) {
            rows.append((String(localized: "Opened by"), Deck.label(opened)))
        }
        if let merged = ProviderDetailFacts.mergedBy(summary) {
            rows.append((String(localized: "Merged by"), Deck.label(merged, color: Theme.merged)))
        }
        if let branches = ProviderDetailFacts.branches(value) {
            rows.append((String(localized: "Branch"), Deck.label(branches, font: Theme.mono, color: Theme.text)))
        }
        let reviews = ProviderDetailFacts.reviewLines(value)
        if !reviews.isEmpty { rows.append((String(localized: "Reviews"), lines(reviews))) }
        if ProviderDetailFacts.hasChecks(value.checks) {
            rows.append((String(localized: "Checks"), checksSummary(value.checks)))
        }
        if let merge = ProviderDetailFacts.merge(value) {
            rows.append((String(localized: "Merge"), Deck.label(merge)))
        }
        // In the Pull Requests list the review is right below; elsewhere this opens it there.
        if showsHeader {
            rows.append((String(localized: "Changes"), Deck.hstack([PartsButton.review(item, from: self)], spacing: 8)))
        }
        content.addArrangedSubview(grid(rows))
    }
    private func checksSummary(_ page: ProviderPage<ProviderCheck>) -> NSView {
        let tally = ProviderDetailFacts.tally(page)
        var views: [NSView] = [
            Deck.label(tally.headline, color: tally.hasFailures ? Theme.failure : Theme.success)
        ]
        for check in tally.listed {
            views.append(stateRow(check.state, ProviderDetailFacts.checkName(check), logs: check.url))
        }
        return Deck.vstack(views, spacing: 3)
    }

    // MARK: Workflow run

    func showWorkflow(_ value: WorkflowRunDetail) {
        if showsHeader {
            let icon = Deck.icon(Style.stateSymbol(value.state), size: 12, color: Theme.color(for: value.state))
            addHeader(icon: icon, title: "#\(value.number) \(value.title)") { [item] in value.url ?? item.url }
        }
        var rows: [Row] = []
        if let workflow = ProviderDetailFacts.workflow(value) {
            rows.append((String(localized: "Workflow"), Deck.label(workflow)))
        }
        if let branch = value.branch {
            rows.append((String(localized: "Branch"), Deck.label(branch, font: Theme.mono, color: Theme.text)))
        }
        if value.attempt > 1 { rows.append((String(localized: "Attempt"), Deck.label("\(value.attempt)"))) }
        let jobs = value.jobs.items.map(jobView)
        let jobsView =
            jobs.isEmpty
            ? Deck.label(ProviderDetailFacts.noJobsText(value), color: Theme.secondaryText)
            : Deck.vstack(jobs, spacing: 3)
        rows.append((String(localized: "Jobs"), jobsView))
        content.addArrangedSubview(grid(rows))
    }
    private func jobView(_ job: WorkflowJob) -> NSView {
        let elapsed = ProviderDetailFacts.elapsed(job.startedAt, job.completedAt)
        var stack: [NSView] = [stateRow(job.state, job.name, caption: elapsed, logs: job.url)]
        if job.state == .failure {
            for step in job.steps where step.state == .failure {
                stack.append(Deck.label("    \(step.number). \(step.name)", font: Theme.caption, color: Theme.failure))
            }
        }
        return Deck.vstack(stack, spacing: 2)
    }

    // MARK: Deployment

    func showDeployment(_ value: DeploymentDetail) {
        var rows: [Row] = []
        let addresses = ProviderDetailFacts.addresses(value)
        if !addresses.isEmpty {
            rows.append((String(localized: "Addresses"), Deck.vstack(addresses.map(addressRow), spacing: 3)))
        }
        if let build = ProviderDetailFacts.build(value) { rows.append((String(localized: "Build"), Deck.label(build))) }
        if let source = ProviderDetailFacts.source(value) {
            rows.append((String(localized: "Source"), Deck.label(source, font: Theme.mono, color: Theme.text)))
        }
        if let reason = ProviderDetailFacts.failureReason(value) {
            rows.append((String(localized: "Reason"), Deck.label(reason, color: Theme.failure)))
        }
        rows.append((String(localized: "Project"), Deck.label(ProviderDetailFacts.project(value))))
        if let dashboard = Deck.safeWebURL(value.dashboardURL) {
            let inspect = PartsButton.link(String(localized: "Inspect ↗"), size: 12) { Deck.open(dashboard) }
            rows.append((String(localized: "Vercel"), Deck.hstack([inspect], spacing: 8)))
        }
        content.addArrangedSubview(grid(rows))
    }
    private func addressRow(_ url: URL) -> NSView {
        let label = Deck.label(url.host ?? url.absoluteString, font: Theme.mono, color: Theme.text)
        return Deck.hstack(
            [
                label, PartsButton.link(String(localized: "Open ↗")) { Deck.open(url) },
                PartsButton.link(String(localized: "Copy")) { Deck.copy(url.absoluteString) },
            ], spacing: 8)
    }

    // MARK: Helpers

    private func addHeader(icon: NSView, title: String, url: @escaping () -> URL?) {
        let label = Deck.label(title, font: Theme.bodyEmphasis)
        let open = PartsButton.openButton(String(localized: "Open on GitHub"), small: true, url: url)
        content.addArrangedSubview(Deck.hstack([icon, label, Deck.spacer(), open], spacing: 7))
    }
    /// A state icon, a name, an optional caption and a "Logs ↗" link when the logs have a safe address.
    private func stateRow(_ state: SignalState, _ name: String, caption: String = "", logs: URL?) -> NSView {
        let icon = Deck.icon(Style.stateSymbol(state), size: 10, color: Theme.color(for: state))
        var row: [NSView] = [icon, Deck.label(name)]
        if !caption.isEmpty { row.append(Deck.caption(caption)) }
        if let url = Deck.safeWebURL(logs) {
            row.append(PartsButton.link(String(localized: "Logs ↗")) { Deck.open(url) })
        }
        return Deck.hstack(row, spacing: 6)
    }
    private func lines(_ values: [String]) -> NSView { Deck.vstack(values.map { Deck.label($0) }, spacing: 2) }
    private func grid(_ rows: [Row]) -> NSView {
        let grid = NSGridView(views: rows.map { [Deck.caption($0.title), $0.view] })
        grid.rowSpacing = 5
        grid.columnSpacing = 10
        grid.column(at: 0).width = 84
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .top }
        for row in rows { row.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return grid
    }
}
