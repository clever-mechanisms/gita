import Foundation
import GitaCore

/// Turns successive provider reports of one repository into notification-worthy events: checks failed / fixed,
/// Preview ready, Production deployed, PR opened / merged / review requested. The first usable report of each kind
/// silently seeds the baseline, so launching or opening a repository never replays history.
@MainActor
final class ProviderNotificationTracker {
    struct Observation {
        let target: ProviderTarget
        var sawProgress: Bool
        var terminalOutcomes: Set<SignalState>
        var seenAt: Date
    }
    struct PullRequestSeen {
        var lifecycle: PullRequestLifecycle
        var reviewRequested: Bool
    }
    struct RunOutcome {
        var number: Int
        var state: SignalState
    }
    private struct Scope {
        let sourceID: String
        let baseline: Date
        var runsSeeded = false
        var pullRequestsSeeded = false
        var observations: [String: Observation] = [:]
        var pullRequests: [Int: PullRequestSeen] = [:]
        /// Latest terminal outcome per workflow + branch, for "checks fixed".
        var workflowOutcomes: [String: RunOutcome] = [:]
    }
    private var scopes: [ProviderKind: Scope] = [:]
    static let observationLimit = 512
    static let itemLimit = 2_048
    private let recordActivity: @MainActor (ProviderReport, RepositorySnapshot) -> Void
    private let viewerLogin: @MainActor () -> String?

    /// `recordActivity` receives every report, so each tab's reports also feed the cross-repository menu bar panel;
    /// `viewerLogin` is the signed-in GitHub account, whose own pull requests never notify.
    init(
        recordActivity: @escaping @MainActor (ProviderReport, RepositorySnapshot) -> Void = {
            ProviderActivity.shared.record($0, snapshot: $1)
        },
        viewerLogin: @escaping @MainActor () -> String?
    ) {
        self.recordActivity = recordActivity
        self.viewerLogin = viewerLogin
    }

    func reset(provider: ProviderKind? = nil) {
        if let provider { scopes[provider] = nil } else { scopes.removeAll(keepingCapacity: false) }
    }

    func observe(
        _ report: ProviderReport, snapshot: RepositorySnapshot, scanStartedAt: Date
    ) -> [ProviderNotificationDestination] {
        recordActivity(report, snapshot)
        guard let source = Self.notifyingSource(report, scanStartedAt: scanStartedAt) else { return [] }
        let bounded = report.items.prefix(Self.itemLimit).filter { $0.provider == report.provider }
        let keyed = bounded.filter { item in
            item.target.flatMap { ProviderNotificationPayload.entityKey(source: source, target: $0) } != nil
        }
        let items = keyed.filter { $0.kind == .workflowRun || $0.kind == .deployment }
        let pullRequests = keyed.filter { $0.kind == .pullRequest && $0.pullRequest != nil }
        let connected = report.status == .connected
        // Partial GitHub data can contain only PRs while the run query failed. Such a response cannot seed an empty
        // workflow baseline; PRs seed their own.
        guard
            connected || report.status == .partial && !(items.isEmpty && pullRequests.isEmpty)
        else { return [] }
        if let current = scopes[report.provider], current.sourceID != source { reset(provider: report.provider) }
        var scope = scopes[report.provider] ?? Scope(sourceID: source, baseline: scanStartedAt)
        let context = ProviderNotificationContext(
            snapshot: snapshot, source: source, baseline: scope.baseline, checkedAt: report.checkedAt)
        var destinations: [ProviderNotificationDestination] = []
        if connected || !items.isEmpty {
            destinations += observeRuns(items, scope: &scope, context: context)
            scope.runsSeeded = true
        }
        if report.provider == .github, connected || !pullRequests.isEmpty {
            destinations += observePullRequests(pullRequests, scope: &scope, context: context)
            scope.pullRequestsSeeded = true
        }
        scopes[report.provider] = scope
        return destinations
    }

    /// The validated hosted source of a GitHub or Vercel report whose times make sense; nil for anything else.
    private static func notifyingSource(_ report: ProviderReport, scanStartedAt: Date) -> String? {
        guard report.provider == .github || report.provider == .vercel, let source = report.sourceID,
            ProviderNotificationPayload.validSource(source, provider: report.provider),
            scanStartedAt.timeIntervalSince1970.isFinite, report.checkedAt.timeIntervalSince1970.isFinite,
            scanStartedAt <= report.checkedAt
        else { return nil }
        return source
    }

    private func observeRuns(
        _ items: [ProviderItem], scope: inout Scope, context: ProviderNotificationContext
    ) -> [ProviderNotificationDestination] {
        let priorAttempts = RunNotificationRules.latestAttempts(scope.observations.values.map(\.target))
        let priorOutcomes = scope.workflowOutcomes
        var destinations: [ProviderNotificationDestination] = []
        for item in items {
            guard let target = item.target,
                let key = ProviderNotificationPayload.entityKey(source: context.source, target: target)
            else { continue }
            let previous = scope.observations[key]
            if scope.runsSeeded,
                RunNotificationRules.isFreshOutcome(
                    item, previous: previous, priorAttempts: priorAttempts, context: context),
                let event = RunNotificationRules.event(for: item, priorOutcomes: priorOutcomes, siblings: items),
                let destination = context.destination(item, target: target, title: item.title, event: event)
            {
                destinations.append(destination)
            }
            scope.observations[key] = RunNotificationRules.observed(
                item, target: target, previous: previous, at: context.checkedAt)
            RunNotificationRules.recordOutcome(item, in: &scope.workflowOutcomes)
        }
        Self.prune(&scope)
        return destinations
    }

    /// The oldest observations go first; outcomes start over once they exceed the limit.
    private static func prune(_ scope: inout Scope) {
        if scope.observations.count > observationLimit {
            let oldest = scope.observations.sorted {
                $0.value.seenAt == $1.value.seenAt ? $0.key < $1.key : $0.value.seenAt < $1.value.seenAt
            }.prefix(scope.observations.count - observationLimit)
            for (key, _) in oldest { scope.observations[key] = nil }
        }
        if scope.workflowOutcomes.count > observationLimit { scope.workflowOutcomes.removeAll(keepingCapacity: false) }
        if scope.pullRequests.count > observationLimit {
            for number in scope.pullRequests.keys.sorted().prefix(scope.pullRequests.count - observationLimit) {
                scope.pullRequests[number] = nil
            }
        }
    }

    private func observePullRequests(
        _ items: [ProviderItem], scope: inout Scope, context: ProviderNotificationContext
    ) -> [ProviderNotificationDestination] {
        let viewer = viewerLogin()?.lowercased()
        var destinations: [ProviderNotificationDestination] = []
        for item in items {
            guard let summary = item.pullRequest, let target = item.target else { continue }
            let previous = scope.pullRequests[summary.number]
            let events =
                scope.pullRequestsSeeded
                ? PullRequestNotificationRules.events(summary, previous: previous, viewer: viewer, context: context)
                : []
            for (event, actor) in events {
                let title = ProviderActivity.pullRequestTitle(item)
                if let destination = context.destination(item, target: target, title: title, event: event, actor: actor)
                {
                    destinations.append(destination)
                }
            }
            scope.pullRequests[summary.number] = PullRequestSeen(
                lifecycle: summary.lifecycle, reviewRequested: summary.reviewRequestedFromViewer)
        }
        Self.prune(&scope)
        return destinations
    }
}
