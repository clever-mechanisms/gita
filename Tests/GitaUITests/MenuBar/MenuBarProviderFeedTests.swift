import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarProviderFeedTests {
    typealias MF = MenuBarFixtures

    private func events(_ items: [ProviderItem], vercel: VercelContext? = nil) -> [FeedEvent] {
        ProviderFeed.events(items, repository: MF.repository, name: "app", vercel: vercel)
    }

    @Test func pullRequestsReportOpenedMergedAndReviewRequested() {
        var merged = MF.PullRequest(
            number:
                8, lifecycle: .merged, author: nil, mergedBy: "lead", merged: MF.now.addingTimeInterval(-10)
        ).make()
        merged.title = "Not prefixed"
        let items = [
            MF.PullRequest(number: 7, review: true).make(), merged,
            MF.PullRequest(number: 9, author: nil, created: nil).make(),
        ]
        let feed = events(items)
        #expect(
            feed.map(\.title) == [
                "octo opened #7", "Review requested on #7", "#8 opened", "lead merged #8",
            ])
        #expect(feed.map(\.kind) == [.pullRequestOpened, .reviewRequested, .pullRequestOpened, .pullRequestMerged])
        #expect(feed[0].detail == "Add things")
        #expect(feed[2].detail == "Not prefixed")
        #expect(feed[0].id == ProviderActivity.key(MF.repository) + "|pr|7|opened")
        #expect(feed.allSatisfy { $0.repositoryName == "app" && $0.sessionID == nil })
    }

    @Test func mergedWithoutMergerReadsPlainly() {
        let item = MF.PullRequest(number: 4, lifecycle: .merged, created: nil, merged: MF.now).make()
        #expect(events([item]).map(\.title) == ["#4 merged"])
    }

    @Test func checksReportTheLatestFailureOrAFix() {
        let failed = events([
            MF.Run(runID: 1, state: .success, number: 1).make(), MF.Run(runID: 2, state: .failure, number: 2).make(),
        ])
        #expect(failed.map(\.kind) == [.checksFailed])
        #expect(failed[0].title == "Checks failed · CI")
        #expect(failed[0].detail == "main · aaaaaaa")

        let fixed = events([
            MF.Run(runID: 1, state: .failure, number: 1).make(), MF.Run(runID: 2, state: .success, number: 2).make(),
        ])
        #expect(fixed.map(\.kind) == [.checksFixed])
        #expect(fixed[0].title == "Checks fixed · CI")

        let quiet = events([
            MF.Run(runID: 1, state: .success, number: 1).make(), MF.Run(runID: 2, state: .success, number: 2).make(),
            MF.Run(runID: 3, state: .running, number: 3).make(),
            MF.Run(runID: 4, state: .failure, number: 4, branch: nil).make(),
            MF.Run(runID: 5, state: .failure, number: 5, branch: "dev", date: nil).make(),
        ])
        #expect(quiet.isEmpty)
    }

    @Test func deploymentsReportTheNewestReadyOnePerEnvironment() throws {
        let production = MF.Deployment(host: "app.vercel.app", environment: .production, date: MF.now).make()
        let custom = MF.Deployment(host: "staging.vercel.app", environment: .custom("Staging")).make()
        let older = MF.Deployment(host: "old.vercel.app", date: MF.now.addingTimeInterval(-500)).make()
        let newer = MF.Deployment(host: "new.vercel.app").make()
        let undated = MF.Deployment(host: "undated.vercel.app", branch: "x", date: nil).make()
        let failed = MF.Deployment(host: "bad.vercel.app", state: .failure, branch: "y").make()
        let feed = events([production, custom, older, newer, undated, failed])
        let titles = Set(feed.map(\.title))
        #expect(titles == ["Production deployed", "Staging ready", "Preview ready"])
        let preview = try #require(feed.first { $0.title == "Preview ready" })
        #expect(preview.kind == .previewReady)
        #expect(feed.first { $0.title == "Production deployed" }?.kind == .productionDeployed)
        #expect(preview.url == URL(string: "https://new.vercel.app"))
        #expect(preview.detail == "aaaaaaa · main")

        var context = VercelContext()
        context.branchPreviews = ["main": URL(string: "https://app-git-main.vercel.app")!]
        context.branchPreviewTargets = ["main": "new.vercel.app"]
        let routed = events([newer], vercel: context)
        #expect(routed.first?.url == URL(string: "https://app-git-main.vercel.app"))
    }

    @Test func agentEventsSkipWorkingAndSubagentsUnderAKnownParent() {
        let worktree = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/app-wt")
        let sessions = [
            MF.Session(id: "n", state: .needsInput, branch: "main", title: "Question").make(),
            MF.Session(id: "d", state: .done, tool: .codex, checkout: worktree, branch: nil).make(),
            MF.Session(id: "w", state: .working).make(),
            MF.Session(id: "s", state: .done, isSubagent: true, parentID: "n").make(),
            MF.Session(id: "loose", state: .done, isSubagent: true, parentID: "gone").make(),
            MF.Session(id: "waiting-sub", state: .needsInput, isSubagent: true).make(),
        ]
        let feed = ProviderFeed.agentEvents(sessions, names: [ProviderActivity.key(MF.repository): "App"])
        #expect(feed.map(\.sessionID) == ["n", "d", "loose"])
        #expect(feed[0].title == "Claude Code needs input")
        #expect(feed[0].detail == "main · Question")
        #expect(feed[0].repositoryName == "App")
        #expect(feed[1].title == "Codex finished")
        #expect(feed[1].detail == "app-wt")
        #expect(feed[0].id == "agent|n|needsInput")
    }

    @Test func newestKeepsTheLastWeekOncePerIDNewestFirst() {
        func event(_ id: String, _ age: TimeInterval) -> FeedEvent {
            FeedEvent(
                id: id, kind: .agentFinished, repository: MF.repository, repositoryName: "app", title: id, detail: "",
                date: MF.now.addingTimeInterval(-age), url: nil, sessionID: nil)
        }
        let input = [
            event("old", 8 * 86_400), event("b", 10), event("a", 10), event("future", -3_600), event("c", 5),
            event("c", 1),
        ]
        #expect(ProviderFeed.newest(input, now: MF.now).map(\.id) == ["c", "a", "b"])
        let many = (0..<50).map { event("e\($0)", TimeInterval($0)) }
        #expect(ProviderFeed.newest(many, now: MF.now).count == ProviderFeed.limit)
    }
}
