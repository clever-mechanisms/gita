import Foundation

/// The Vercel adapter: the linked project's latest deployments, their context and signals, one deployment's
/// details and a failed build's log, all through the existing CLI session in the linked checkout.
struct VercelProvider: Sendable {
    static let contextLifetime: TimeInterval = 600

    let executor: ProviderCommandExecutor
    let platformCache: VercelPlatformCache
    let clock: @Sendable () -> Date

    var links: VercelLinkResolver { VercelLinkResolver(executor: executor) }

    /// The deployment list and the link it was read through.
    func list(root: URL) async -> (report: ProviderReport, link: VercelLink?) {
        guard let link = await links.resolve(root) else {
            if Task.isCancelled { return (ProviderReport(.vercel, failure: .cancelled), nil) }
            let diagnostic = String(
                localized: """
                    No unambiguous Vercel link. This worktree’s declared link must be readable and valid; sibling \
                    fallback requires at most 256 Git worktrees whose valid links all identify the same project.
                    """)
            return (ProviderReport(.vercel, status: .notLinked, diagnostic: diagnostic), nil)
        }
        let response = await executor.execute(.vercel, ["list", "--json", "--limit", "30"], in: link.root).flatMap {
            data in
            Result { try VercelDeploymentParser.items(data) }.mapError { _ in
                ProviderFailure.unsupportedResponse(.vercel)
            }
        }
        switch response {
        case .failure(let failure):
            return (
                ProviderReport(
                    .vercel, status: failure.status, diagnostic: failure.diagnostic, sourceID: link.sourceID),
                link
            )
        case .success(let items):
            // The link is resolved again after the read so a project change cannot relabel its deployments.
            let current = await links.resolve(root)
            guard current?.sourceID == link.sourceID, VercelLinkReader.sourceID(at: link.root) == link.sourceID else {
                let diagnostic = String(
                    localized: "The linked Vercel project changed during the read. Refresh to load its deployments.")
                return (ProviderReport(.vercel, status: .projectChanged, diagnostic: diagnostic), link)
            }
            let diagnostic = String(localized: "Latest 30 deployments from this repository’s linked Vercel project.")
            return (
                ProviderReport(
                    .vercel, items: items, status: .connected, diagnostic: diagnostic, sourceID: link.sourceID),
                link
            )
        }
    }

    /// The deployment list plus gated context and signals. `previous` is the last published Vercel report.
    func report(root: URL, previous: ProviderReport?, forceContext: Bool) async -> ProviderReport {
        var (report, link) = await list(root: root)
        // A failed list keeps no context: production facts without their deployments would be stale.
        guard report.status == .connected, let link, !Task.isCancelled else { return report }
        let same = previous?.sourceID == link.sourceID
        let fingerprint = VercelContext.fingerprint(report.items)
        if !forceContext, same, let context = previous?.vercel, isCurrent(context, fingerprint: fingerprint) {
            report.vercel = context
        } else {
            report.vercel = await VercelContextReader(executor: executor, clock: clock).read(
                link: link, items: report.items)
        }
        guard !Task.isCancelled else { return report }
        let reader = VercelSignalReader(executor: executor, cache: platformCache, clock: clock)
        let signals = await reader.read(
            link: link, live: report.vercel?.production?.deploymentID, fingerprint: fingerprint,
            previous: same ? previous?.vercelSignals : nil, force: forceContext)
        report.vercelSignals = signals
        report.items += signals.ciItems()
        return report
    }

    /// A context read from the same deployment list within its lifetime, by a clock that did not go backwards.
    private func isCurrent(_ context: VercelContext, fingerprint: String) -> Bool {
        let age = clock().timeIntervalSince(context.readAt)
        return context.fingerprint == fingerprint && age >= 0 && age < Self.contextLifetime
    }

    /// Last 20 lines of a failed build. Display only: never cached beyond the caller, logged or persisted.
    func buildLog(root: URL, reference: String, scope: String?) async -> VercelBuildLog {
        guard let reference = VercelIdentifiers.deploymentReference(reference), VercelIdentifiers.isScope(scope) else {
            return VercelBuildLog(failure: .invalidIdentity)
        }
        guard let link = await links.resolve(root) else { return VercelBuildLog(failure: .notLinked) }
        let endpoint = "/v3/deployments/\(reference)/events?builds=1&direction=backward&limit=40"
        switch await executor.execute(.vercel, VercelCommands.get(endpoint, scope: scope), in: link.root) {
        case .failure(let failure): return VercelBuildLog(failure: failure)
        case .success(let data):
            guard let lines = try? VercelBuildLog.lines(data) else {
                return VercelBuildLog(failure: .unverified(.vercel))
            }
            return VercelBuildLog(lines: lines, status: .connected)
        }
    }
}
