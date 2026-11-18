import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// What needs the user, the order of the workspaces and where a card's pills go: the panel's pure parts.
@MainActor
@Suite struct MenuBarPanelAttentionTests {
    typealias MF = MenuBarFixtures
    private let worktree = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/app-feature", isDirectory: true)
    private let page = URL(string: "https://github.com/owner/app/pull/482")!
    private let run = URL(string: "https://github.com/owner/app/actions/runs/9")!

    private func repository() -> MenuPanelState.Repository {
        MenuPanelState.Repository(root: MF.repository, name: "app", branch: "feat/checkout")
    }

    // MARK: Needs you

    @Test func nothingWaitsWithoutAgentsReviewsFailuresOrConflicts() {
        var repo = repository()
        repo.checks = MF.checks(.success)
        repo.pullRequests = [.init(number: 1, title: "One", reviewRequested: false)]
        let source = PanelAttention.Source(
            repositories: [repo],
            sessions: [MF.Session(id: "w", state: .working).make(), MF.Session(id: "d", state: .done).make()])
        #expect(PanelAttention.items(source).isEmpty)
        #expect(PanelAttention.items(.init()).isEmpty)
    }

    @Test func aWaitingAgentNamesItsRepositoryWorktreeAndTask() throws {
        let sessions = [
            MF.Session(id: "n", state: .needsInput, checkout: worktree, title: "Approve the build").make(),
            MF.Session(id: "m", state: .needsInput, tool: .codex, repository: MF.site).make(),
        ]
        let items = PanelAttention.items(
            .init(sessions: sessions, names: [ProviderActivity.key(MF.repository): "gita-app"]))
        let first = try #require(items.first { $0.id == "agent:n" })
        #expect(first.kind == .agentWaiting(tool: .claudeCode, session: "n"))
        #expect(first.detail == "gita-app · app-feature · Approve the build")
        #expect(first.repository == worktree)
        #expect(first.date == sessions[0].stateSince)
        #expect(first.url == nil)
        // In the main checkout, without a task: the repository alone, named after its folder.
        #expect(items.first { $0.id == "agent:m" }?.detail == "site")
    }

    @Test func aRequestedReviewOpensThePullRequestAndFailingChecksTheirRun() throws {
        var repo = repository()
        repo.pullRequests = [
            .init(number: 482, title: "Checkout", reviewRequested: true, url: page, date: MF.now),
            .init(number: 7, title: "Other", reviewRequested: false),
        ]
        repo.checks = .init(
            state: .failure, run: .init(name: "CI / test", url: run, date: MF.now.addingTimeInterval(-60)))
        let items = PanelAttention.items(.init(repositories: [repo]))
        #expect(items.map(\.kind) == [.reviewRequested, .checksFailed])
        #expect(items[0].id == "review:\(repo.id)#482")
        #expect(items[0].detail == "app · #482 Checkout")
        #expect(items[0].url == page)
        #expect(items[1].id == "checks:" + repo.id)
        #expect(items[1].detail == "app · feat/checkout · CI / test")
        #expect(items[1].url == run)
        #expect(items[1].repository == MF.repository)
    }

    @Test func conflictsComeFirstThenTheNewest() {
        var repo = repository()
        repo.pullRequests = [
            .init(number: 1, title: "Old", reviewRequested: true, date: MF.now.addingTimeInterval(-3_600)),
            .init(number: 2, title: "Undated", reviewRequested: true),
        ]
        repo.checks = MF.checks(.failure, date: MF.now.addingTimeInterval(-600))
        let source = PanelAttention.Source(
            repositories: [repo],
            sessions: [MF.Session(id: "n", state: .needsInput, since: MF.now.addingTimeInterval(-60)).make()],
            conflicts: MF.repository)
        let items = PanelAttention.items(source)
        #expect(
            items.map(\.id) == [
                "conflicts:" + repo.id, "review:\(repo.id)#2", "agent:n", "checks:" + repo.id, "review:\(repo.id)#1",
            ])
        #expect(items[0].kind == .conflicts)
        #expect(items[0].detail == "app · feat/checkout")
        #expect(items[0].date == nil)
        // Conflicts in a repository that is in no tab are still named.
        let elsewhere = PanelAttention.items(.init(conflicts: MF.site))
        #expect(elsewhere.map(\.detail) == ["site"])
    }

    // MARK: Workspaces

    @Test func workspacesAreOrderedFrontThenWindowsThenRestingThenClosed() {
        let listed = [
            MF.workspace("a", presence: .closed), MF.workspace("b", presence: .window),
            MF.workspace("c", presence: .closed), MF.workspace("d", presence: .front),
            MF.workspace("e", presence: .window), MF.workspace("f", presence: .resting),
        ]
        #expect(MenuPanelState.Workspace.ordered(listed).map(\.id) == ["d", "b", "e", "f", "a", "c"])
        #expect(MenuPanelState.Workspace.ordered([]).isEmpty)
        #expect(MenuPanelState.Workspace.Presence.front < .window)
        #expect(MenuPanelState.Workspace.Presence.window < .closed)
        #expect(MF.workspace().repositories == [MF.repository.path])
    }

    // MARK: Pills

    @Test func pillsWrapLikeWordsInALine() {
        #expect(PanelPillLayout.frames([], available: 100).isEmpty)
        let frames = PanelPillLayout.frames([40, 40, 40, 100, 20], available: 100)
        #expect(frames.map(\.origin.x) == [0, 44, 0, 0, 0])
        #expect(frames.map(\.origin.y) == [0, 0, 26, 52, 78])
        #expect(frames.allSatisfy { $0.height == PanelPillLayout.height })
        // A pill wider than the row is cut to it; one that just fits stays on the line.
        #expect(PanelPillLayout.frames([300], available: 100)[0].width == 100)
        #expect(PanelPillLayout.frames([48, 48], available: 100).map(\.origin.y) == [0, 0])
        #expect(PanelPillLayout.frames([48, 49], available: 100).map(\.origin.y) == [0, 26])
    }

    @Test func aWorkspaceCardIsAsHighAsItsPillsNeed() {
        #expect(PanelPillLayout.height([], available: 100) == 0)
        #expect(PanelPillLayout.height([40, 40], available: 100) == 22)
        #expect(PanelPillLayout.height([40, 40, 40], available: 100) == 48)
        #expect(PanelCard.pillsWidth == Theme.panelWidth - 40)
        // Header alone, one line of pills, two lines; each with the gap under the card.
        #expect(PanelCard.workspaceHeight([]) == 43)
        #expect(PanelCard.workspaceHeight([100, 100]) == 72)
        #expect(PanelCard.workspaceHeight([200, 200]) == 98)
        let twelve = Array(repeating: CGFloat(100), count: 12)
        // Three to a line: four lines of 22 with three gaps of 4, under the header and its 7.
        #expect(PanelCard.workspaceHeight(twelve) == 150)
        var row = PanelRow(id: "w", kind: .workspace)
        #expect(row.height == 43)
        row.pills = twelve.map { PanelPill(id: "p", title: "p", width: $0) }
        #expect(row.height == PanelCard.workspaceHeight(twelve))
    }
}
