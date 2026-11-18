import Foundation
import GitaCore

/// One repository's provider items as the panel shows them: checks (with the run they come from), the deployment to
/// open, open pull requests.
extension ProviderActivity {
    static func checks(_ items: [ProviderItem], branch: String?) -> MenuPanelState.Checks? {
        let runs = items.filter { $0.kind == .workflowRun && (branch == nil || $0.branch == branch) }
        let ordered = latestPerWorkflow(runs).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard let newest = ordered.first else { return nil }
        func checks(_ state: SignalState, from run: ProviderItem) -> MenuPanelState.Checks {
            .init(state: state, run: .init(name: run.category, url: run.url, date: run.date))
        }
        if let failed = ordered.first(where: { $0.state == .failure }) { return checks(.failure, from: failed) }
        if let running = ordered.first(where: { $0.state == .running || $0.state == .pending }) {
            return checks(.running, from: running)
        }
        guard ordered.allSatisfy({ $0.state == .success || $0.state == .cancelled || $0.state == .neutral }) else {
            return nil
        }
        return checks(ordered.contains { $0.state == .success } ? .success : .neutral, from: newest)
    }

    /// The latest run of each workflow; runs without a run number (Vercel CI) compare by date.
    private static func latestPerWorkflow(_ runs: [ProviderItem]) -> [ProviderItem] {
        var latest: [String: ProviderItem] = [:]
        for run in runs {
            let key = run.workflowDatabaseID.map(String.init) ?? run.category
            if let current = latest[key], order(current) >= order(run) { continue }
            latest[key] = run
        }
        return Array(latest.values)
    }

    /// Run number, then date: the newer run sorts higher.
    static func order(_ run: ProviderItem) -> (Int, Date) { (run.workflowRunNumber ?? 0, run.date ?? .distantPast) }

    /// The panel's Preview and Production buttons open each deployment's main URL (`VercelContext.primaryURL`).
    static func deployments(
        _ items: [ProviderItem], branch: String?, vercel: VercelContext? = nil
    ) -> (preview: MenuPanelState.Deployment?, production: MenuPanelState.Deployment?) {
        let ready = items.filter { $0.kind == .deployment && $0.state == .success && $0.url != nil }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        func make(_ item: ProviderItem?) -> MenuPanelState.Deployment? {
            guard let item, let url = vercel?.primaryURL(for: item) ?? item.url else { return nil }
            return .init(url: url, state: item.state)
        }
        let production = ready.first { $0.deployment?.environment == .production }
        let previews = ready.filter { $0.deployment?.environment != .production }
        let preview = previews.first { branch != nil && $0.branch == branch } ?? previews.first
        return (make(preview), make(production))
    }

    static func pullRequests(_ items: [ProviderItem]) -> [MenuPanelState.PullRequest] {
        items.compactMap { item -> MenuPanelState.PullRequest? in
            guard item.kind == .pullRequest, let summary = item.pullRequest,
                summary.lifecycle == .open
            else { return nil }
            return .init(
                number: summary.number, title: pullRequestTitle(item),
                reviewRequested: summary.reviewRequestedFromViewer, url: item.url,
                date: item.date ?? summary.createdAt)
        }.sorted { $0.reviewRequested != $1.reviewRequested ? $0.reviewRequested : $0.number > $1.number }
    }

    /// A summary item's title is "#7 Title"; feeds and notifications show the number separately.
    static func pullRequestTitle(_ item: ProviderItem) -> String {
        guard let number = item.pullRequest?.number else { return item.title }
        let prefix = "#\(number) "
        return item.title.hasPrefix(prefix) ? String(item.title.dropFirst(prefix.count)) : item.title
    }
}
