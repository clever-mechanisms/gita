import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Successive provider reports and agent sessions turned into the events worth a notification.
@MainActor
@Suite struct NotificationsTrackerTests {
    typealias NF = NotificationsFixtures
    typealias MF = MenuBarFixtures

    @MainActor final class Recorded {
        var reports = 0
    }

    private func tracker(_ recorded: Recorded = Recorded(), viewer: String? = "me") -> ProviderNotificationTracker {
        ProviderNotificationTracker(recordActivity: { _, _ in recorded.reports += 1 }, viewerLogin: { viewer })
    }

    private func observe(
        _ tracker: ProviderNotificationTracker, _ provider: ProviderKind, _ items: [ProviderItem],
        status: ProviderStatus = .connected, started: Date
    ) -> [AttentionKind?] {
        tracker.observe(
            MF.report(provider, items, status: status, checkedAt: Date()), snapshot: MF.snapshot(),
            scanStartedAt: started
        ).map(\.event)
    }

    // MARK: Runs

    @Test func theFirstReportSeedsThenFailuresAndFixesNotify() {
        let recorded = Recorded()
        let tracker = tracker(recorded)
        let start = Date().addingTimeInterval(-300)
        #expect(observe(tracker, .github, [NF.run(.failure, runID: 1, number: 1)], started: start).isEmpty)
        #expect(observe(tracker, .github, [NF.run(.running, runID: 2, number: 2)], started: start).isEmpty)
        #expect(observe(tracker, .github, [NF.run(.success, runID: 2, number: 2)], started: start) == [.checksFixed])
        #expect(observe(tracker, .github, [NF.run(.success, runID: 2, number: 2)], started: start).isEmpty)
        #expect(observe(tracker, .github, [NF.run(.failure, runID: 3, number: 3)], started: start) == [.checksFailed])
        #expect(recorded.reports == 5)
    }

    @Test func runsThatStartedBeforeTheBaselineStayQuiet() {
        let tracker = tracker()
        let start = Date()
        #expect(observe(tracker, .github, [], started: start).isEmpty)
        var old = NF.run(.failure, runID: 4, number: 4)
        old.startedAt = start.addingTimeInterval(-3_600)
        #expect(observe(tracker, .github, [old], started: start).isEmpty)
        // A new attempt of a known run notifies even though the run started long ago.
        var retry = old
        retry.target = .workflowRun(repository: "owner/app", runID: 4, attempt: 2)
        retry.state = .failure
        #expect(observe(tracker, .github, [old, retry], started: start) == [.checksFailed])
    }

    @Test func deploymentsAnnounceReadyAndProduction() {
        let tracker = tracker()
        let start = Date().addingTimeInterval(-300)
        #expect(observe(tracker, .vercel, [], started: start).isEmpty)
        let events = observe(
            tracker, .vercel,
            [NF.deployment("a.vercel.app"), NF.deployment("p.vercel.app", environment: .production)], started: start)
        #expect(events == [.previewReady, .productionDeployed])
        #expect(
            observe(tracker, .vercel, [NF.deployment("b.vercel.app", state: .failure)], started: start)
                == [.checksFailed])
    }

    @Test func unusableReportsNeverNotifyOrSeed() {
        let tracker = tracker()
        let start = Date().addingTimeInterval(-300)
        let failed = [NF.run(.failure, runID: 7, number: 7)]
        #expect(observe(tracker, .github, failed, status: .offline, started: start).isEmpty)
        #expect(observe(tracker, .github, [], status: .partial, started: start).isEmpty)
        #expect(observe(tracker, .orca, failed, started: start).isEmpty)
        #expect(observe(tracker, .github, failed, started: Date().addingTimeInterval(60)).isEmpty)
        let foreign = tracker.observe(
            MF.report(.github, failed, source: "github:other/repo"), snapshot: MF.snapshot(), scanStartedAt: start)
        #expect(foreign.isEmpty)
        // Partial data with items seeds runs; the next failure then notifies.
        #expect(observe(tracker, .github, failed, status: .partial, started: start).isEmpty)
        #expect(
            observe(tracker, .github, [NF.run(.failure, runID: 8, number: 8)], status: .partial, started: start)
                == [.checksFailed])
        tracker.reset(provider: .github)
        #expect(observe(tracker, .github, [NF.run(.failure, runID: 9, number: 9)], started: start).isEmpty)
        tracker.reset()
        #expect(observe(tracker, .github, [NF.run(.failure, runID: 10, number: 10)], started: start).isEmpty)
    }

    @Test func aNewSourceStartsOver() {
        let tracker = tracker()
        let start = Date().addingTimeInterval(-300)
        #expect(observe(tracker, .github, [], started: start).isEmpty)
        let moved = tracker.observe(
            MF.report(
                .github,
                [
                    MF.Run(runID: 1, state: .failure, number: 1, date: Date(), started: Date(), repository: "owner/new")
                        .make()
                ],
                source: "github:owner/new"),
            snapshot: MF.snapshot(), scanStartedAt: start)
        #expect(moved.isEmpty)
    }

    @Test func observationsArePrunedPastTheLimit() {
        let tracker = tracker()
        let start = Date().addingTimeInterval(-300)
        let many = (1...(ProviderNotificationTracker.observationLimit + 5)).map {
            NF.run(.success, runID: Int64($0), number: $0)
        }
        let pulls = (1...(ProviderNotificationTracker.observationLimit + 5)).map { NF.pullRequest($0) }
        #expect(observe(tracker, .github, many + pulls, started: start).isEmpty)
        // The lowest-numbered pull requests were forgotten, so they read as new again.
        #expect(
            observe(tracker, .github, many + pulls, started: start) == Array(repeating: .pullRequestOpened, count: 5))
        #expect(
            observe(tracker, .github, [NF.run(.failure, runID: 9_999, number: 9_999)], started: start)
                == [.checksFailed])
    }

    // MARK: Pull requests

    @Test func pullRequestsByOthersNotifyOpenedMergedAndReview() {
        let tracker = tracker()
        let start = Date().addingTimeInterval(-300)
        #expect(observe(tracker, .github, [NF.pullRequest(1)], started: start).isEmpty)
        #expect(
            observe(tracker, .github, [NF.pullRequest(1), NF.pullRequest(2)], started: start) == [.pullRequestOpened])
        #expect(observe(tracker, .github, [NF.pullRequest(2, review: true)], started: start) == [.reviewRequested])
        var merged = NF.pullRequest(2, review: true)
        merged.pullRequest?.lifecycle = .merged
        merged.pullRequest?.mergedBy = "lead"
        #expect(observe(tracker, .github, [merged], started: start) == [.pullRequestMerged])
        var mine = NF.pullRequest(3)
        mine.pullRequest?.author = "ME"
        #expect(observe(tracker, .github, [mine], started: start).isEmpty)
    }

    @Test func pullRequestRulesAreJudgedAgainstWhatWasSeen() {
        let context = NF.context()
        let recent = Date().addingTimeInterval(-60)
        typealias Seen = ProviderNotificationTracker.PullRequestSeen
        func events(_ summary: PullRequestSummary, _ previous: Seen?, viewer: String? = "me") -> [AttentionKind] {
            PullRequestNotificationRules.events(summary, previous: previous, viewer: viewer, context: context).map(\.0)
        }
        let open = PullRequestSummary(number: 1, lifecycle: .open, isDraft: false, author: "octo", createdAt: recent)
        #expect(events(open, nil) == [.pullRequestOpened])
        #expect(events(open, Seen(lifecycle: .open, reviewRequested: false)).isEmpty)
        var anonymous = open
        anonymous.author = "me"
        #expect(events(anonymous, nil).isEmpty)
        #expect(events(anonymous, nil, viewer: nil) == [.pullRequestOpened])
        var merged = open
        merged.lifecycle = .merged
        merged.mergedAt = recent
        #expect(events(merged, nil) == [.pullRequestMerged])
        #expect(events(merged, Seen(lifecycle: .merged, reviewRequested: false)).isEmpty)
        var review = open
        review.reviewRequestedFromViewer = true
        #expect(events(review, Seen(lifecycle: .open, reviewRequested: true)).isEmpty)
        #expect(events(review, Seen(lifecycle: .open, reviewRequested: false)) == [.reviewRequested])
    }

    // MARK: Run rules

    @Test func runRulesTrackAttemptsOutcomesAndGroups() {
        let targets: [ProviderTarget] = [
            .workflowRun(repository: "o/a", runID: 1, attempt: 1),
            .workflowRun(repository: "o/a", runID: 1, attempt: 3),
            .pullRequest(repository: "o/a", number: 1),
        ]
        #expect(RunNotificationRules.latestAttempts(targets) == [1: 3])
        var outcomes: [String: RunNotificationRules.RunOutcome] = [:]
        RunNotificationRules.recordOutcome(NF.run(.failure, runID: 1, number: 5), in: &outcomes)
        RunNotificationRules.recordOutcome(NF.run(.success, runID: 2, number: 4), in: &outcomes)
        RunNotificationRules.recordOutcome(NF.run(.running, runID: 3, number: 6), in: &outcomes)
        #expect(outcomes.values.map(\.number) == [5])
        let fix = NF.run(.success, runID: 4, number: 6)
        #expect(RunNotificationRules.event(for: fix, priorOutcomes: outcomes, siblings: []) == .checksFixed)
        #expect(RunNotificationRules.event(for: fix, priorOutcomes: [:], siblings: []) == nil)
        let sibling = NF.run(.failure, runID: 5, number: 5)
        #expect(RunNotificationRules.event(for: fix, priorOutcomes: [:], siblings: [sibling]) == .checksFixed)
        #expect(RunNotificationRules.event(for: NF.pullRequest(), priorOutcomes: [:], siblings: []) == nil)
        var unnamed = fix
        unnamed.branch = ""
        #expect(RunNotificationRules.workflowGroup(unnamed) == nil)
        #expect(RunNotificationRules.workflowGroup(NF.deployment()) == nil)

        let context = NF.context()
        let seen = RunNotificationRules.observed(
            NF.run(.running), target: NF.run().target!, previous: nil, at: Date())
        #expect(seen.sawProgress)
        #expect(RunNotificationRules.isFreshOutcome(NF.run(), previous: seen, priorAttempts: [:], context: context))
        let finished = RunNotificationRules.observed(NF.run(), target: NF.run().target!, previous: seen, at: Date())
        #expect(
            !RunNotificationRules.isFreshOutcome(NF.run(), previous: finished, priorAttempts: [:], context: context))
        #expect(
            !RunNotificationRules.isFreshOutcome(NF.run(.running), previous: nil, priorAttempts: [:], context: context))
        let quiet = RunNotificationRules.observed(NF.run(.success), target: NF.run().target!, previous: nil, at: Date())
        #expect(!RunNotificationRules.isFreshOutcome(NF.run(), previous: quiet, priorAttempts: [:], context: context))
    }

    @Test func contextJudgesRecencyWithSkew() {
        let context = NF.context()
        #expect(context.isRecent(Date()))
        #expect(context.isRecent(Date().addingTimeInterval(200)))
        #expect(!context.isRecent(Date().addingTimeInterval(1_000)))
        #expect(!context.isRecent(Date().addingTimeInterval(-3_600)))
        #expect(!context.isRecent(nil))
        var broken = NF.run()
        broken.url = URL(string: "https://github.com/owner/app/actions/runs/999")
        #expect(context.destination(broken, target: broken.target!, title: "CI", event: .checksFailed) == nil)
    }

    // MARK: Agents

    @Test func agentTrackerSeedsThenReportsCrossings() {
        var clock = Date()
        let tracker = AgentAttentionTracker(now: { clock })
        let old = MF.Session(id: "old", state: .done, since: clock.addingTimeInterval(-600)).make()
        #expect(tracker.observe([old]).isEmpty)
        clock = clock.addingTimeInterval(10)
        var working = MF.Session(id: "w", state: .working, since: clock).make()
        let fresh = MF.Session(id: "new", state: .needsInput, since: clock).make()
        let stale = MF.Session(id: "stale", state: .done, since: clock.addingTimeInterval(-3_600)).make()
        let sub = MF.Session(id: "sub", state: .done, since: clock, isSubagent: true).make()
        #expect(tracker.observe([old, working, fresh, stale, sub]).map(\.0.id) == ["new"])
        #expect(tracker.observe([old, working, fresh]).isEmpty)
        working.state = .done
        working.stateSince = clock.addingTimeInterval(5)
        var again = fresh
        again.stateSince = clock.addingTimeInterval(5)
        let crossings = tracker.observe([old, working, again])
        #expect(crossings.map(\.0.id) == ["w", "new"])
        #expect(crossings.map(\.1) == [.agentFinished, .agentNeedsInput])
    }
}
