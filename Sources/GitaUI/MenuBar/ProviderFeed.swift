import Foundation
import GitaCore

/// Pure: provider items and agent sessions → the menu bar panel's Activity events.
@MainActor
enum ProviderFeed {
    static let horizon: TimeInterval = 7 * 86_400
    static let limit = 40

    /// Within the last week (and not after now, with skew), one per id, newest first, at most `limit`.
    static func newest(_ events: [FeedEvent], now: Date) -> [FeedEvent] {
        let earliest = now.addingTimeInterval(-horizon)
        let latest = now.addingTimeInterval(ProviderNotificationContext.skew)
        var seen = Set<String>()
        return events.filter { $0.date >= earliest && $0.date <= latest && seen.insert($0.id).inserted }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    /// The repository both events and their ids belong to.
    private struct Place {
        let repository: URL
        let name: String
        let key: String

        func event(
            _ id: String, _ kind: AttentionKind, title: String, detail: String, date: Date, url: URL?
        ) -> FeedEvent {
            FeedEvent(
                id: "\(key)|\(id)", kind: kind, repository: repository, repositoryName: name, title: title,
                detail: detail, date: date, url: url, sessionID: nil)
        }
    }

    static func events(
        _ items: [ProviderItem], repository: URL, name: String, vercel: VercelContext? = nil
    ) -> [FeedEvent] {
        let place = Place(repository: repository, name: name, key: ProviderActivity.key(repository))
        return items.filter { $0.kind == .pullRequest }.flatMap { pullRequestEvents($0, place) }
            + checkEvents(items, place) + deploymentEvents(items, place, vercel: vercel)
    }

    private static func pullRequestEvents(_ item: ProviderItem, _ place: Place) -> [FeedEvent] {
        guard let summary = item.pullRequest else { return [] }
        let number = summary.number
        let title = ProviderActivity.pullRequestTitle(item)
        var events: [FeedEvent] = []
        if let created = summary.createdAt {
            let text =
                summary.author.map { String(localized: "\($0) opened #\(number)") }
                ?? String(localized: "#\(number) opened")
            events.append(
                place.event(
                    "pr|\(number)|opened", .pullRequestOpened, title: text, detail: title, date: created, url: item.url)
            )
        }
        if summary.lifecycle == .merged, let merged = summary.mergedAt {
            let text =
                summary.mergedBy.map { String(localized: "\($0) merged #\(number)") }
                ?? String(localized: "#\(number) merged")
            events.append(
                place.event(
                    "pr|\(number)|merged", .pullRequestMerged, title: text, detail: title, date: merged, url: item.url))
        }
        if summary.reviewRequestedFromViewer, summary.lifecycle == .open,
            let date = item.date ?? summary.createdAt
        {
            events.append(
                place.event(
                    "pr|\(number)|review", .reviewRequested, title: String(localized: "Review requested on #\(number)"),
                    detail: title, date: date, url: item.url))
        }
        return events
    }

    /// The latest finished run per workflow and branch: failed, or fixed when the run before it failed.
    private static func checkEvents(_ items: [ProviderItem], _ place: Place) -> [FeedEvent] {
        let runs = Dictionary(grouping: items.filter { $0.kind == .workflowRun && $0.branch != nil }) {
            "\($0.workflowDatabaseID.map(String.init) ?? $0.category)\u{0}\($0.branch ?? "")"
        }
        return runs.values.compactMap { group in
            let finished = group.filter { RunNotificationRules.isTerminal($0.state) }
                .sorted { ProviderActivity.order($0) > ProviderActivity.order($1) }
            guard let latest = finished.first, let date = latest.date else { return nil }
            let detail = [latest.branch, latest.commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(
                separator: " · ")
            if latest.state == .failure {
                return place.event(
                    "\(latest.id)|failed", .checksFailed,
                    title: String(localized: "Checks failed · \(latest.category)"),
                    detail: detail, date: date, url: latest.url)
            }
            guard finished.dropFirst().first?.state == .failure else { return nil }
            return place.event(
                "\(latest.id)|fixed", .checksFixed, title: String(localized: "Checks fixed · \(latest.category)"),
                detail: detail, date: date, url: latest.url)
        }
    }

    /// The newest ready deployment per environment and branch.
    private static func deploymentEvents(
        _ items: [ProviderItem], _ place: Place, vercel: VercelContext?
    )
        -> [FeedEvent]
    {
        let deployments = Dictionary(grouping: items.filter { $0.kind == .deployment && $0.state == .success }) {
            "\($0.deployment?.environment.name ?? "")\u{0}\($0.branch ?? "")"
        }
        return deployments.values.compactMap { group in
            guard let latest = group.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }),
                let date = latest.date
            else { return nil }
            let detail = [latest.commit.map { String($0.prefix(7)) }, latest.branch].compactMap { $0 }.joined(
                separator: " · ")
            let production = latest.deployment?.environment == .production
            return place.event(
                "\(latest.id)|ready", production ? .productionDeployed : .previewReady,
                title: readyTitle(latest.deployment?.environment), detail: detail, date: date,
                url: vercel?.primaryURL(for: latest) ?? latest.url)
        }
    }

    private static func readyTitle(_ environment: DeploymentSummary.Environment?) -> String {
        switch environment {
        case .production: String(localized: "Production deployed")
        case .custom(let environment): String(localized: "\(environment) ready")
        default: String(localized: "Preview ready")
        }
    }

    /// Agents that finished or wait for input. Twelve subagents finishing are one agent's work, not twelve feed
    /// entries: only loose subagents report, and only when done.
    static func agentEvents(_ sessions: [AgentSession], names: [String: String]) -> [FeedEvent] {
        sessions.compactMap { session -> FeedEvent? in
            guard let kind = AttentionKind(agentState: session.state), !session.isSubagent || session.state == .done
            else { return nil }
            if session.isSubagent, let parent = session.parentID, sessions.contains(where: { $0.id == parent }) {
                return nil
            }
            let repository = PanelRowBuilder.home(session)
            let tool = session.tool.displayName
            let title =
                kind == .agentNeedsInput
                ? String(localized: "\(tool) needs input") : String(localized: "\(tool) finished")
            var detail = [session.branch, session.title].compactMap { $0 }.joined(separator: " · ")
            if let checkout = session.checkoutRoot, ProviderActivity.key(checkout) != ProviderActivity.key(repository) {
                detail = [checkout.lastPathComponent, detail].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return FeedEvent(
                id: "agent|\(session.id)|\(session.state.rawValue)", kind: kind, repository: repository,
                repositoryName: names[ProviderActivity.key(repository)] ?? repository.lastPathComponent, title: title,
                detail: detail, date: session.stateSince, url: nil, sessionID: session.id)
        }
    }
}
