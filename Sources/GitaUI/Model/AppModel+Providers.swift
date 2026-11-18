import Foundation
import GitaCore

/// GitHub, Vercel and Orca: reading them, publishing what they report and the signals each commit shows.
extension AppModel {
    /// The reports of the integrations that are on; a switched-off one's last report stays out of sight.
    var reports: [ProviderReport] { providers.reports.filter { Integration.isEnabled($0.provider, defaults) } }
    var allSignals: [ProviderItem] { providers.signals.items }
    /// Commits with provider signals (the only rows, with agents and unpushed ones, whose Status chips need measuring).
    var signaledCommitIDs: Dictionary<String, [ProviderItem]>.Keys { providers.signals.byCommit.keys }
    func signals(for commit: GitCommit?) -> [ProviderItem] {
        guard let commit else { return [] }
        return providers.signals.byCommit[commit.id] ?? []
    }

    /// GitHub and Vercel each refresh on their own when their switch is on; Orca, being local, follows either.
    private var refreshesProviders: Bool {
        Preference.providerRefresh.bool(defaults) || Preference.vercelRefresh.bool(defaults)
    }
    /// The integrations a timer or a window coming back reads (`refreshesProviders` gates whether it runs).
    private var automaticIntegrations: Set<Integration> {
        var integrations: Set<Integration> = [.orca, .agents]
        if Preference.providerRefresh.bool(defaults) { integrations.insert(.github) }
        if Preference.vercelRefresh.bool(defaults) { integrations.insert(.vercel) }
        return integrations
    }

    // MARK: Timers

    func minuteTick() {
        if dirty && isObserved { refresh() }
        guard isActiveRepository, refreshesProviders else { return }
        let due = ProviderRefreshPolicy.minuteTickRefreshes(
            foreground: isForegroundObserved, pending: ProviderRefreshPolicy.hasPendingSignals(allSignals),
            lastStarted: providers.lastRefreshStartedAt, now: Date())
        if due { refreshProviders(automatic: true) }
    }

    func agentsTick() {
        guard isForegroundObserved, isActiveRepository, refreshesProviders else { return }
        refreshAgents()
    }

    func vercelTick() {
        guard isForegroundObserved, isActiveRepository, Preference.vercelRefresh.bool(defaults),
            ProviderRefreshPolicy.vercelInFlight(providers.reports)
        else { return }
        refreshVercel()
    }

    func refreshVisibleContext() {
        guard isObserved else { return }
        if dirty { refresh() }
        guard isForegroundObserved, refreshesProviders else { return }
        switch ProviderRefreshPolicy.onBecomingVisible(
            lastStarted: providers.lastRefreshStartedAt, agentsCheckedAt: providers.report(.orca)?.checkedAt,
            now: Date())
        {
        case .all: refreshProviders(automatic: true)
        case .agents: refreshAgents()
        case .none: break
        }
    }

    // MARK: Reads

    /// Reads every integration that is on; `automatic` reads skip GitHub or Vercel when its own refresh is off.
    func refreshProviders(automatic: Bool = false) {
        guard let root, let snapshot, !providers.full.isRunning else { return }
        // A full refresh owns the next agent observation. An older fast poll
        // must not publish after it and restore stale working/idle metadata.
        providers.cancelFastReads()
        let scanStartedAt = Date()
        providers.lastRefreshStartedAt = scanStartedAt
        let current = generation
        let client = providerService
        let integrations = Set(
            Integration.allCases.filter { $0.isEnabled(defaults) && (!automatic || automaticIntegrations.contains($0)) }
        )
        // A read that leaves Vercel out keeps the context request for the next read that includes Vercel.
        let forceContext = integrations.contains(.vercel) && takeVercelRequest()
        let accounts = GitHubAccountStore(defaults: defaults)
        let github = snapshot.github
        let reads = Self.integrationReads(
            integrations, client: client, root: root,
            github: (snapshot.remoteURL, github, accounts.choice(for: github?.sourceID)),
            vercel: (providers.report(.vercel), forceContext))
        dependencies.lookUpAvatars(root, github, client)
        let id = UUID()
        providers.full = .running(
            id,
            Task { [weak self] in
                await withTaskGroup(of: IntegrationResult.self) { group in
                    for read in reads { group.addTask(operation: read) }
                    for await read in group {
                        guard let self, !Task.isCancelled, self.generation == current else {
                            group.cancelAll()
                            return
                        }
                        if let viewer = read.viewer, !viewer.isEmpty { self.providers.viewerLogin = viewer }
                        accounts.apply(read.account, sourceID: github?.sourceID)
                        self.publish(read.report, scanStartedAt: scanStartedAt)
                    }
                }
                self?.providerReadEnded(\.full, id)
            })
    }

    /// A provider read ended however it ended: idle again, and (unless another read replaced it) the Vercel read
    /// asked for while it ran starts.
    func providerReadEnded(_ read: WritableKeyPath<ProviderState, InFlightRead>, _ id: UUID) {
        guard providers[keyPath: read].end(id), providers.vercelRequest == .contextAfterRead else { return }
        refreshVercel()
    }

    /// Whether the Vercel read starting now refreshes the context too; the request is then used up.
    func takeVercelRequest() -> Bool {
        defer { providers.vercelRequest = .none }
        return providers.vercelRequest != .none
    }

    typealias IntegrationResult = (report: ProviderReport, viewer: String?, account: GitHubAccountUpdate)
    typealias IntegrationRead = @Sendable () async -> IntegrationResult

    /// One read per integration switched on. GitHub's read also names the signed-in account and what to remember
    /// about it for this repository; the others name none.
    private static func integrationReads(
        _ enabled: Set<Integration>, client: ProviderService, root: URL,
        github: (remoteURL: String?, remote: GitHubRemote?, choice: GitHubAccountChoice?),
        vercel: (previous: ProviderReport?, forceContext: Bool)
    ) -> [IntegrationRead] {
        var reads: [IntegrationRead] = []
        if enabled.contains(.github) {
            reads.append {
                let listing = await client.github(
                    root: root, remoteURL: github.remoteURL, remote: github.remote, choice: github.choice)
                return (listing.report, listing.viewerLogin, listing.account)
            }
        }
        if enabled.contains(.vercel) {
            reads.append {
                (
                    await client.vercel(root: root, previous: vercel.previous, forceContext: vercel.forceContext), nil,
                    .keep
                )
            }
        }
        if enabled.contains(.orca) { reads.append { (await client.orca(root: root), nil, .keep) } }
        return reads
    }

    private func refreshAgents() {
        guard let root, snapshot != nil, !providers.full.isRunning, !providers.agents.isRunning,
            Integration.orca.isEnabled(defaults)
        else { return }
        let current = generation
        let client = providerService
        let id = UUID()
        providers.agents = .running(
            id,
            Task { [weak self] in
                let report = await client.orca(root: root)
                guard let self else { return }
                self.providers.agents.end(id)
                guard !Task.isCancelled, self.generation == current else { return }
                self.publish(report)
            })
    }

    func publish(_ report: ProviderReport, scanStartedAt: Date? = nil) {
        let previous = providers.report(report.provider)
        let changed = report.differs(from: previous)
        providers.reports.removeAll { $0.provider == report.provider }
        providers.reports.append(report)
        if report.provider == .vercel {
            updateProductionBehind()
            announceNewVercelAlerts(report)
        }
        if let snapshot {
            let destinations = notificationTracker.observe(
                report, snapshot: snapshot, scanStartedAt: scanStartedAt ?? report.checkedAt)
            if !destinations.isEmpty {
                let notify = dependencies.notifyProvider
                Task { for destination in destinations { await notify(destination) } }
            }
        }
        guard changed else {
            if isMenuVisible || section == .agents || section == .connections { emit(.providers) }
            return
        }
        providers.details.retain(listedIn: report)
        rebuildSignalIndex()
        if report.statusDiffers(from: previous), let diagnostic = report.diagnostic {
            logStatus(report.provider, status: report.status, diagnostic: diagnostic)
        }
        emit(.providers)
    }

    func rebuildSignalIndex() {
        providers.signals = SignalIndex(reports: reports, worktrees: snapshot?.worktrees ?? [])
    }

    /// An integration was switched on or off: what it showed goes or comes back, and one switched on is read.
    func integrationChanged(_ integration: Integration) {
        guard integration.provider != nil else { return }
        rebuildSignalIndex()
        emit(.providers)
        if integration.isEnabled(defaults), isActiveRepository { refreshProviders() }
    }

    private func logStatus(_ provider: ProviderKind, status: ProviderStatus, diagnostic: String) {
        log(
            String(localized: "\(provider.displayName): \(status.localizedTitle)"), diagnostic,
            failed: status != .connected)
    }

    // MARK: Details of one item

    /// Detail reads only run after an explicit selection. Closing the main
    /// window also invalidates in-flight cache publication to release metadata.
    func clearProviderDetails() { providers.details.removeAll() }

    func providerDetails(
        for item: ProviderItem, target: ProviderTarget, forceRefresh: Bool
    ) async
        -> ProviderDetailReport
    {
        guard item.target == target, let root = snapshot?.root else {
            return ProviderDetailReport(
                target: target, content: nil, status: .unavailable,
                diagnostic: String(localized: "Open the repository again to load these details."))
        }
        let current = generation
        let epoch = providers.details.epoch
        if !forceRefresh, let cached = providers.details.report(for: target, item: item, now: Date()) { return cached }
        let account = GitHubAccountStore(defaults: defaults).use(for: target.githubSourceID)
        let report = await providerService.details(root: root, target: target, githubAccount: account)
        guard !Task.isCancelled else { return ProviderDetailReport(target: target, content: nil, status: .cancelled) }
        guard generation == current, snapshot?.root == root else {
            return ProviderDetailReport(
                target: target, content: nil, status: .repositoryChanged,
                diagnostic: String(localized: "Reopen the item from the current repository."))
        }
        if report.content != nil, report.target == target, providers.details.epoch == epoch,
            allSignals.contains(where: { $0.target == target && $0 == item })
        {
            providers.details.store(report, for: target, item: item, now: Date())
        }
        if let diagnostic = report.diagnostic {
            logStatus(item.provider, status: report.status, diagnostic: diagnostic)
        }
        return report
    }
}
