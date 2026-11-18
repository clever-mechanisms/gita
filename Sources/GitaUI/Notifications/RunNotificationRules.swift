import Foundation
import GitaCore

/// When a workflow run or deployment notifies, as pure functions over what the tracker has seen.
enum RunNotificationRules {
    typealias Observation = ProviderNotificationTracker.Observation
    typealias RunOutcome = ProviderNotificationTracker.RunOutcome

    /// The newest attempt seen of each workflow run.
    static func latestAttempts(_ targets: [ProviderTarget]) -> [Int64: Int] {
        var attempts: [Int64: Int] = [:]
        for case .workflowRun(_, let runID, let attempt) in targets {
            attempts[runID] = max(attempts[runID] ?? 0, attempt)
        }
        return attempts
    }

    /// A finished outcome this item has not reported yet, after it was seen in progress, or (seen for the first
    /// time) when it started after the baseline or is a newer attempt of a known run.
    static func isFreshOutcome(
        _ item: ProviderItem, previous: Observation?, priorAttempts: [Int64: Int], context: ProviderNotificationContext
    ) -> Bool {
        guard isTerminal(item.state), previous?.terminalOutcomes.contains(item.state) != true else { return false }
        if previous?.sawProgress == true { return true }
        guard previous == nil else { return false }
        return context.isRecent(item.startedAt) || isNewerAttempt(item.target, priorAttempts: priorAttempts)
    }

    private static func isNewerAttempt(_ target: ProviderTarget?, priorAttempts: [Int64: Int]) -> Bool {
        guard case .workflowRun(_, let runID, let attempt) = target, let prior = priorAttempts[runID] else {
            return false
        }
        return attempt > prior
    }

    static func isTerminal(_ state: SignalState) -> Bool { state == .success || state == .failure }

    /// The item's observation after this report.
    static func observed(
        _ item: ProviderItem, target: ProviderTarget, previous: Observation?, at date: Date
    )
        -> Observation
    {
        var observation =
            previous ?? Observation(target: target, sawProgress: false, terminalOutcomes: [], seenAt: date)
        if isTerminal(item.state) { observation.terminalOutcomes.insert(item.state) }
        if item.state == .pending || item.state == .running { observation.sawProgress = true }
        observation.seenAt = date
        return observation
    }

    /// Keeps the newest finished run per workflow and branch.
    static func recordOutcome(_ item: ProviderItem, in outcomes: inout [String: RunOutcome]) {
        guard isTerminal(item.state), let group = workflowGroup(item), let number = item.workflowRunNumber,
            number >= outcomes[group]?.number ?? 0
        else { return }
        outcomes[group] = RunOutcome(number: number, state: item.state)
    }

    /// Runs: a failure is "checks failed"; a success only matters when it fixes the previous failure of the same
    /// workflow on the same branch. Deployments: ready → Preview/Production, error → failed.
    static func event(
        for item: ProviderItem, priorOutcomes: [String: RunOutcome], siblings: [ProviderItem]
    )
        -> AttentionKind?
    {
        switch item.kind {
        case .workflowRun:
            if item.state == .failure { return .checksFailed }
            return previousOutcome(of: item, priorOutcomes: priorOutcomes, siblings: siblings)?.state == .failure
                ? .checksFixed : nil
        case .deployment:
            if item.state == .failure { return .checksFailed }
            return item.deployment?.environment == .production ? .productionDeployed : .previewReady
        default:
            return nil
        }
    }

    /// The latest finished run before this one in its workflow and branch, from earlier reports or this one.
    private static func previousOutcome(
        of item: ProviderItem, priorOutcomes: [String: RunOutcome], siblings: [ProviderItem]
    ) -> RunOutcome? {
        guard let group = workflowGroup(item), let number = item.workflowRunNumber else { return nil }
        var previous = priorOutcomes[group].flatMap { $0.number < number ? $0 : nil }
        for sibling in siblings where workflowGroup(sibling) == group {
            guard let other = sibling.workflowRunNumber, other < number, isTerminal(sibling.state),
                other > previous?.number ?? 0
            else { continue }
            previous = RunOutcome(number: other, state: sibling.state)
        }
        return previous
    }

    static func workflowGroup(_ item: ProviderItem) -> String? {
        guard item.kind == .workflowRun, let id = item.workflowDatabaseID, let branch = item.branch, !branch.isEmpty
        else { return nil }
        return "\(id)\u{0}\(branch)"
    }
}
