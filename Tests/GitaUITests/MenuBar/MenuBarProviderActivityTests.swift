import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarProviderActivityTests {
    typealias MF = MenuBarFixtures

    @Test func recordsReportsPerRepositoryAndNotifiesOncePerBurst() async {
        let activity = ProviderActivity()
        var calls = 0
        activity.observe { calls += 1 }
        activity.record(
            MF.report(.github, [MF.Run(runID: 1, state: .success, number: 1).make()]), snapshot: MF.snapshot())
        activity.record(
            MF.report(.vercel, [MF.Deployment(host: "a.vercel.app").make()], checkedAt: MF.now.addingTimeInterval(5)),
            snapshot: MF.snapshot(branch: "dev"))
        await MF.drainMainQueue()
        #expect(calls == 1)
        let entry = activity.entry(for: MF.repository)
        #expect(entry?.branch == "dev")
        #expect(entry?.items.count == 2)
        #expect(entry?.checkedAt == MF.now.addingTimeInterval(5))
        #expect(activity.checkedAt == MF.now.addingTimeInterval(5))
    }

    @Test func removedObserversHearNothing() async {
        let activity = ProviderActivity()
        var calls = 0
        let token = activity.observe { calls += 1 }
        activity.removeObserver(token)
        activity.record(MF.report(.github, []), snapshot: MF.snapshot())
        await MF.drainMainQueue()
        #expect(calls == 0)
    }

    @Test func entriesAreBoundedOldestFirst() {
        let activity = ProviderActivity(entryLimit: 2)
        let roots = ["a", "b", "c"].map { URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/\($0)") }
        for root in roots { activity.record(MF.report(.github, []), snapshot: MF.snapshot(root)) }
        #expect(activity.entries.count == 2)
        #expect(activity.entry(for: roots[0]) == nil)
        #expect(activity.entry(for: roots[2]) != nil)
    }

    @Test func aWorktreeEntryStandsInForItsMainCheckout() {
        let activity = ProviderActivity()
        let worktree = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/app-wt")
        var snapshot = MF.snapshot(worktree)
        snapshot.commonGitDirectory = MF.repository.appendingPathComponent(".git")
        activity.record(MF.report(.github, []), snapshot: snapshot)
        #expect(activity.entry(for: MF.repository)?.root == worktree)
        #expect(activity.entry(for: MF.site) == nil)
    }

    @Test func feedJoinsProviderAndAgentEvents() {
        let activity = ProviderActivity()
        activity.record(MF.report(.github, [MF.PullRequest(number: 5).make()]), snapshot: MF.snapshot())
        let feed = activity.feed(
            sessions: [MF.Session(id: "d", state: .done).make()], names: [ProviderActivity.key(MF.repository): "App"],
            now: MF.now)
        #expect(Set(feed.map(\.kind)) == [.pullRequestOpened, .agentFinished])
        #expect(feed.allSatisfy { $0.repositoryName == "App" })
    }

    @Test func problemNamesTheBrokenProviderAndRepository() {
        let activity = ProviderActivity()
        #expect(activity.problem(names: [:]) == nil)
        activity.record(MF.report(.github, [], status: .signInRequired), snapshot: MF.snapshot())
        #expect(activity.problem(names: [:]) == "GitHub · Sign in required · app")
        activity.record(MF.report(.vercel, [], status: .offline), snapshot: MF.snapshot(MF.site))
        #expect(activity.problem(names: [:])?.hasSuffix("2 repositories") == true)
        #expect(activity.problem(names: [:])?.hasPrefix("GitHub · ") == true)
    }

    @Test func vercelIncidentIsReportedWhenNothingIsBroken() {
        let activity = ProviderActivity()
        var report = MF.report(.vercel, [])
        report.vercelSignals = VercelSignals(platform: .init(indicator: "major", summary: "Builds delayed"))
        activity.record(report, snapshot: MF.snapshot())
        #expect(activity.problem(names: [:])?.hasPrefix("Vercel · ") == true)
        var calm = MF.report(.vercel, [])
        calm.vercelSignals = VercelSignals(platform: .init(indicator: "none", summary: "All good"))
        activity.record(calm, snapshot: MF.snapshot())
        #expect(activity.problem(names: [:]) == nil)
    }

    // MARK: Projections

    @Test func checksSummariseTheLatestRunOfEachWorkflow() {
        let passing = [
            MF.Run(runID: 1, state: .failure, number: 1).make(), MF.Run(runID: 2, state: .success, number: 2).make(),
        ]
        #expect(ProviderActivity.checks(passing, branch: "main")?.state == .success)
        let failing = passing + [MF.Run(runID: 3, state: .failure, number: 1, workflow: 10).make()]
        let failed = ProviderActivity.checks(failing, branch: "main")
        #expect(failed?.state == .failure)
        // The failing run is the one the checks name and open.
        #expect(failed?.run.name == "CI")
        #expect(failed?.run.url == URL(string: "https://github.com/owner/app/actions/runs/3"))
        #expect(failed?.run.date == MF.now.addingTimeInterval(-30))
        #expect(
            ProviderActivity.checks(passing, branch: "main")?.run.url
                == URL(string: "https://github.com/owner/app/actions/runs/2"))
        let running = [MF.Run(runID: 4, state: .pending, number: 1).make()]
        #expect(ProviderActivity.checks(running, branch: nil)?.state == .running)
        let neutral = [MF.Run(runID: 5, state: .cancelled, number: 1).make()]
        #expect(ProviderActivity.checks(neutral, branch: "main")?.state == .neutral)
        #expect(ProviderActivity.checks(passing, branch: "other") == nil)
        let odd = [
            MF.Run(runID: 6, state: .success, number: 1).make(),
            MF.Run(runID: 7, state: .neutral, number: 1, workflow: 11).make(),
        ]
        #expect(ProviderActivity.checks(odd, branch: "main")?.state == .success)
        var unknown = MF.Run(runID: 8, state: .success, number: 1).make()
        unknown.state = .running
        unknown.workflowRunNumber = nil
        #expect(ProviderActivity.checks([unknown], branch: "main")?.state == .running)
    }

    @Test func deploymentsPickTheBranchPreviewAndProduction() {
        let items = [
            MF.Deployment(host: "other.vercel.app", branch: "dev", date: MF.now).make(),
            MF.Deployment(host: "mine.vercel.app", date: MF.now.addingTimeInterval(-100)).make(),
            MF.Deployment(host: "prod.vercel.app", environment: .production).make(),
            MF.Deployment(host: "failed.vercel.app", state: .failure).make(),
        ]
        let picked = ProviderActivity.deployments(items, branch: "main")
        #expect(picked.preview?.url == URL(string: "https://mine.vercel.app"))
        #expect(picked.production?.url == URL(string: "https://prod.vercel.app"))
        #expect(
            ProviderActivity.deployments(items, branch: nil).preview?.url == URL(string: "https://other.vercel.app"))
        #expect(ProviderActivity.deployments([], branch: nil).preview == nil)
    }

    @Test func openPullRequestsListReviewsFirstThenNewest() {
        let items = [
            MF.PullRequest(number: 1).make(), MF.PullRequest(number: 3).make(),
            MF.PullRequest(number: 2, review: true).make(),
            MF.PullRequest(number: 4, lifecycle: .merged).make(), MF.Run(runID: 1, state: .success, number: 1).make(),
        ]
        let pulls = ProviderActivity.pullRequests(items)
        #expect(pulls.map(\.number) == [2, 3, 1])
        #expect(pulls[0].title == "Add things")
        #expect(pulls[0].reviewRequested)
        #expect(pulls[0].url == URL(string: "https://github.com/owner/app/pull/2"))
        #expect(pulls[0].date == MF.now.addingTimeInterval(-60))
    }

    @Test func pullRequestTitleDropsOnlyItsOwnNumber() {
        var item = MF.PullRequest(number: 12).make()
        #expect(ProviderActivity.pullRequestTitle(item) == "Add things")
        item.title = "#13 Other"
        #expect(ProviderActivity.pullRequestTitle(item) == "#13 Other")
        item.pullRequest = nil
        #expect(ProviderActivity.pullRequestTitle(item) == "#13 Other")
    }
}
