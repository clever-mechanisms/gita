import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarPanelRowBuilderTests {
    typealias MF = MenuBarFixtures
    private let worktree = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/app-feature", isDirectory: true)

    private func builder(_ state: MenuPanelState, expanded: Set<String> = []) -> PanelRowBuilder {
        PanelRowBuilder(state: state, expanded: expanded, now: MF.now)
    }

    private func repository(
        branch: String? = "main", ahead: Int = 0, behind: Int = 0, changed: Int = 0
    ) -> MenuPanelState.Repository {
        MenuPanelState.Repository(
            root: MF.repository, name: "app", branch: branch, ahead: ahead, behind: behind, changedFiles: changed)
    }

    private func item(
        _ id: String, _ kind: PanelAttention.Item.Kind, date: Date? = nil, url: URL? = nil
    ) -> PanelAttention.Item {
        .init(id: id, kind: kind, repository: MF.repository, detail: "app · detail", date: date, url: url)
    }

    // MARK: Needs you

    @Test func anEmptyInboxSaysNothingNeedsYou() {
        let rows = builder(MenuPanelState()).rows(.inbox)
        #expect(rows.map(\.id) == ["calm"])
        #expect(rows[0].kind == .message)
        #expect(rows[0].title == "Nothing needs you")
        #expect(!rows[0].isSelectable)
    }

    @Test func pendingUpdateAppearsAsTopCardAndHidesWhenCleared() throws {
        var state = MenuPanelState()
        #expect(builder(state).updateRows().isEmpty)

        state.pendingUpdateVersion = "0.2.3"
        let rows = builder(state).rows(.inbox)
        #expect(rows.first?.id == "update:available")
        let row = try #require(rows.first)
        #expect(row.kind == .attention)
        #expect(row.title == "Version 0.2.3 is available")
        #expect(row.subtitle == "Software updates")
        #expect(row.action == .installUpdate)
        #expect(row.chips.map(\.title) == ["Install Update"])
        #expect(row.chips.first?.style == .accent)
        #expect(row.chips.first?.action == .installUpdate)
        #expect(row.lead == .symbol("arrow.down.circle.fill", .accentText))
        #expect(builder(state).rows(.activity).allSatisfy { $0.id != "update:available" })
    }

    @Test func everyKindOfItemIsACardWithOneChip() throws {
        let page = try #require(URL(string: "https://github.com/owner/app/pull/482"))
        let state = MenuPanelState(attention: [
            item("agent:n", .agentWaiting(tool: .codex, session: "n"), date: MF.now.addingTimeInterval(-180)),
            item("review:1", .reviewRequested, date: MF.now.addingTimeInterval(-3_600), url: page),
            item("review:2", .reviewRequested), item("checks:1", .checksFailed, url: page),
            item("conflicts:1", .conflicts),
        ])
        let rows = builder(state).rows(.inbox).filter { $0.kind == .attention }
        #expect(rows.map(\.id).first == "attention:agent:n")
        #expect(
            rows.map(\.title) == [
                "Codex is waiting", "Review requested", "Review requested", "Checks failed", "Conflicts",
            ])
        #expect(rows.map { $0.chips.map(\.title) } == [["Terminal"], ["Review"], ["Review"], ["Open ↗"], ["Show"]])
        #expect(
            rows.map(\.action) == [
                .reveal("n"), .openURL(page), .showRepository(MF.repository), .openURL(page),
                .showRepository(MF.repository),
            ])
        #expect(rows.allSatisfy { $0.chips[0].action == $0.action && $0.subtitle == "app · detail" })
        #expect(rows[0].chips[0].style == .attention)
        #expect(rows[0].chips[0].label == "Bring Codex forward")
        #expect(rows[1].chips[0].style == .quiet)
        #expect(rows[0].time == PanelTime.duration(since: MF.now.addingTimeInterval(-180), now: MF.now, units: 1))
        #expect(rows[4].time == nil)
        #expect(rows[0].label == "Codex is waiting, app · detail, " + (rows[0].time ?? ""))
        #expect(rows[4].label == "Conflicts, app · detail")
        #expect(rows[1].link == page.absoluteString)
        #expect(rows[0].lead == .symbol("bubble.left.fill", .needsInputText))
        #expect(rows[3].lead == .symbol("xmark", .failure))
        #expect(rows[0].height == 52 && rows[0].isCard)
    }

    // MARK: Agents

    @Test func noAgentsMeansNoAgentsSection() {
        let waiting = MenuPanelState(sessions: [MF.Session(id: "n", state: .needsInput).make()])
        #expect(builder(waiting).rows(.inbox).map(\.id) == ["calm"])
        #expect(builder(MenuPanelState()).agentRows().isEmpty)
    }

    @Test func agentsAreWorkingThenDoneWithIdleFoldedAndWaitingLeftToNeedsYou() {
        let state = MenuPanelState(
            repositories: [repository()],
            sessions: [
                MF.Session(id: "d", state: .done).make(), MF.Session(id: "w", state: .working).make(),
                MF.Session(id: "n", state: .needsInput).make(), MF.Session(id: "i1", state: .idle).make(),
                MF.Session(id: "i2", state: .idle, repository: MF.site).make(),
            ],
            names: [ProviderActivity.key(MF.site): "web"])
        let rows = builder(state).agentRows()
        #expect(rows.map(\.id) == ["section:agents", "agent:w", "agent:d", "idle"])
        #expect(rows[0].kind == .header)
        #expect(rows[0].title == "Agents" && rows[0].count == "2")
        #expect(rows[0].label == "Agents, 2")
        #expect(rows[1].kind == .line && rows[1].height == 28)
        let idle = rows[3]
        #expect(idle.title == "Idle · app, web")
        #expect(idle.disclosure == .collapsed)
        #expect(idle.action == .toggle("idle"))

        let open = builder(state, expanded: ["idle"]).agentRows()
        #expect(open.suffix(2).map(\.id) == ["agent:i1", "agent:i2"])
        #expect(open.first { $0.id == "idle" }?.disclosure == .expanded)
    }

    @Test func idleSummaryShowsThreeNamesThenACount() {
        let roots = ["a", "b", "c", "d", "e"].map { URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/\($0)") }
        let sessions = roots.enumerated().map { MF.Session(id: "i\($0)", state: .idle, repository: $1).make() }
        let rows = builder(MenuPanelState(sessions: sessions)).agentRows()
        #expect(rows.map(\.id) == ["section:agents", "idle"])
        // Nothing works: the caption has no count.
        #expect(rows[0].count == nil && rows[0].label == "Agents")
        #expect(rows[1].title == "Idle · a, b, c, +2")
        #expect(rows[1].label == "Idle, 5: a, b, c, d, e")
    }

    @Test func aWorkingLineNamesItsTaskCountsSubagentsAndOpensItsPreview() throws {
        var repo = repository(ahead: 1, changed: 2)
        repo.preview = .init(url: try #require(URL(string: "https://preview.example.com")), state: .success)
        let sessions = [
            MF.Session(id: "w", state: .working, title: "Account switcher").make(),
            MF.Session(id: "s1", state: .working, isSubagent: true, parentID: "w").make(),
            MF.Session(id: "s2", state: .done, isSubagent: true, parentID: "w").make(),
        ]
        let rows = builder(MenuPanelState(repositories: [repo], sessions: sessions)).agentRows()
        #expect(rows.map(\.id) == ["section:agents", "agent:w"])
        #expect(rows[0].count == "1")
        let row = rows[1]
        #expect(row.title == "app")
        #expect(row.subtitle == "Account switcher · 2 subagents")
        #expect(row.subtitleTool == .claudeCode)
        #expect(row.toolTip == "main ↑1 · 2 modified · Preview ready")
        #expect(row.time == PanelTime.duration(since: MF.now.addingTimeInterval(-120), now: MF.now))
        #expect(row.chips.map(\.title) == ["Open ↗"])
        #expect(row.chips.map(\.action) == [.openURL(try #require(repo.preview).url)])
        #expect(row.hoverChip?.action == .showRepository(MF.repository))
        #expect(row.action == .reveal("w"))
        #expect(row.label.hasPrefix("app, Working, Account switcher"))
    }

    @Test func aDoneLineSaysSoAndAnUntitledOneNamesItsBranch() throws {
        let sessions = [MF.Session(id: "d", state: .done, tool: .codex, branch: "fix/webhooks").make()]
        let row = try #require(builder(MenuPanelState(sessions: sessions)).agentRows().last)
        #expect(row.subtitle == "fix/webhooks · Done")
        #expect(row.chips.isEmpty)
        #expect(row.lead == .mark(AgentMarkState(tool: .codex, state: .done)))
    }

    @Test func worktreeAgentIsNamedAfterItsFolderAndSkipsMainCheckoutFacts() throws {
        var repo = repository(ahead: 3, changed: 4)
        repo.preview = .init(url: try #require(URL(string: "https://preview.example.com")), state: .success)
        let sessions = [
            MF.Session(id: "t", state: .working, checkout: worktree, branch: "app-feature").make(),
            MF.Session(id: "u", state: .done, checkout: worktree, branch: "other", isSubagent: true).make(),
        ]
        let rows = builder(MenuPanelState(repositories: [repo], sessions: sessions)).agentRows()
        let working = try #require(rows.first { $0.id == "agent:t" })
        #expect(working.title == "app · app-feature")
        #expect(working.subtitle?.isEmpty == true)
        #expect(working.toolTip?.isEmpty == true)
        #expect(working.chips.isEmpty)
        #expect(working.hoverChip?.action == .showRepository(worktree))
        #expect(working.label == "app · app-feature, Working, " + (working.time ?? ""))
        let done = try #require(rows.first { $0.id == "agent:u" })
        #expect(done.subtitle == "Subagent · other · Done")
        #expect(done.toolTip == "other")
    }

    // MARK: Workspaces

    @Test func eachWorkspaceIsACardThatSaysWhereItIs() {
        let state = MenuPanelState(
            repositories: [repository()],
            workspaces: [
                MF.workspace("a", title: "Gitā", presence: .front),
                MF.workspace("b", title: "Client work", presence: .window, repositories: []),
                MF.workspace("c", title: "Open source", presence: .closed),
            ])
        let rows = builder(state).workspaceRows()
        #expect(rows.map(\.id) == ["section:workspaces", "workspace:a", "workspace:b", "workspace:c"])
        #expect(rows[0].title == "Workspaces" && rows[0].count == nil)
        let (front, window, closed) = (rows[1], rows[2], rows[3])
        #expect(front.kind == .workspace && front.isCard)
        #expect(front.title == "Gitā")
        #expect(front.status == "In front" && front.statusColor == .accentText)
        #expect(front.action == .openWorkspace("a"))
        #expect(front.chips.isEmpty && !front.outlined)
        #expect(front.label == "Gitā, In front")
        #expect(window.status == "Window" && window.statusColor == .secondary)
        #expect(window.pills.isEmpty)
        #expect(window.height == PanelCard.workspaceHeight([]))
        #expect(closed.status == nil && closed.suffix == "Closed" && closed.outlined)
        #expect(closed.chips.map(\.title) == ["Open"])
        #expect(closed.chips.map(\.action) == [.openWorkspace("c")])
        #expect(closed.chips[0].label == "Open “Open source”")
        #expect(closed.action == .openWorkspace("c"))
        #expect(builder(MenuPanelState()).workspaceRows().isEmpty)
    }

    @Test func aPillShowsItsRepositorysMarkNameAndCountsAndOpensItsTab() throws {
        var app = repository(ahead: 2, behind: 3, changed: 1)
        app.agents.needsInput = 1
        app.checks = MF.checks(.failure)
        app.preview = .init(url: try #require(URL(string: "https://app-git-main.vercel.app")), state: .success)
        app.pullRequests = [.init(number: 7, title: "Seven", reviewRequested: false)]
        var site = MenuPanelState.Repository(root: MF.site, name: "site", branch: "main")
        site.checks = MF.checks(.success)
        let state = MenuPanelState(
            repositories: [app, site],
            workspaces: [MF.workspace("a", repositories: [MF.repository, MF.site, worktree])],
            sessions: [
                MF.Session(id: "n", state: .needsInput).make(),
                MF.Session(id: "i", state: .idle, repository: MF.site).make(),
            ])
        let pills = try #require(builder(state).workspaceRows().last).pills
        #expect(pills.map(\.title) == ["app", "site", "app-feature"])
        #expect(pills.map(\.id) == [app.id, site.id, worktree.path])
        #expect(pills[0].mark == .agent(AgentMarkState(tool: .claudeCode, state: .needsInput)))
        #expect(pills[0].counts == "↑2 ↓3")
        #expect(pills[0].tinted)
        #expect(pills[0].action == .showTab(MF.repository, workspace: "a"))
        #expect(pills[0].menu.map(\.title) == ["Show in Gitā", "Push 2", "Open Preview", "Copy Path"])
        #expect(
            pills[0].menu.map(\.action) == [
                .showTab(MF.repository, workspace: "a"), .push(MF.repository),
                .openURL(try #require(app.preview).url), .copy(MF.repository.path),
            ])
        #expect(
            pills[0].toolTip
                == "app\nmain ↑2 ↓3 · 1 modified · 1 open PRs · 1 needs input\nChecks: failing\n#7 Seven")
        // An idle agent does not hide the checks.
        #expect(pills[1].mark == .checks(.success))
        #expect(pills[1].counts == nil && !pills[1].tinted)
        #expect(pills[1].menu.map(\.title) == ["Show in Gitā", "Copy Path"])
        // A tab the monitor has not reported yet is named after its folder.
        #expect(pills[2].mark == .none && pills[2].toolTip == "app-feature")
        #expect(pills.allSatisfy { $0.width == PanelPillButton.width($0) && $0.width > 20 })
        #expect(pills[0].width > pills[1].width)
    }

    @Test func aClosedWorkspacesPillsAreLabels() throws {
        let state = MenuPanelState(
            repositories: [repository(ahead: 1)], workspaces: [MF.workspace("c", presence: .closed)])
        let pill = try #require(builder(state).workspaceRows().last?.pills.first)
        #expect(pill.action == nil)
        #expect(pill.menu.isEmpty)
        #expect(pill.counts == "↑1")
        #expect(pill.toolTip == "app\nmain ↑1")
    }

    @Test func theRestingWorkspaceReadsClosedButItsPillsOpenTheirTabs() throws {
        let state = MenuPanelState(repositories: [repository()], workspaces: [MF.workspace(presence: .resting)])
        let row = try #require(builder(state).workspaceRows().last)
        #expect(row.suffix == "Closed" && row.outlined && row.status == nil)
        #expect(row.chips.map(\.action) == [.openWorkspace("default")])
        #expect(row.pills.map(\.action) == [.showTab(MF.repository, workspace: "default")])
        #expect(row.pills[0].menu.count == 2)
    }

    @Test func reviewsAndErrorsReadInTheFacts() {
        var repo = repository()
        repo.pullRequests = [.init(number: 3, title: "Three", reviewRequested: true)]
        repo.agents.working = 1
        #expect(PanelRowBuilder.facts(repo) == ["main", "1 to review", "1 working"])
        repo.error = "Not found"
        #expect(PanelRowBuilder.facts(repo) == ["Not found"])
        #expect(PanelRowBuilder.toolTip(repo) == "app\nNot found\n#3 Three")
    }

    @Test(arguments: [
        (AgentSummary.with(done: 2), "2 done"), (AgentSummary(), nil),
    ])
    func agentFactNamesTheMostUrgentState(_ agents: AgentSummary, _ expected: String?) {
        var repo = repository(branch: nil)
        repo.agents = agents
        #expect(PanelRowBuilder.facts(repo).last == expected)
    }

    @Test func aRepositorysMarkPrefersATopLevelAgentAndTurnsWhileAnyWorks() {
        let repo = repository()
        let sessions = [
            MF.Session(id: "sub", state: .needsInput, isSubagent: true).make(),
            MF.Session(id: "top", state: .done, tool: .codex).make(),
            MF.Session(id: "busy", state: .working, isSubagent: true).make(),
            MF.Session(id: "elsewhere", state: .needsInput, repository: MF.site).make(),
        ]
        #expect(PanelRowBuilder.agentMark(repo, sessions: sessions) == AgentMarkState(tool: .codex, state: .working))
        #expect(
            PanelRowBuilder.agentMark(repo, sessions: [sessions[0]])
                == AgentMarkState(tool: .claudeCode, state: .needsInput))
        #expect(PanelRowBuilder.agentMark(repo, sessions: []) == nil)
    }

    @Test func theInboxListsNeedsYouThenAgentsThenWorkspaces() {
        let state = MenuPanelState(
            repositories: [repository()], workspaces: [MF.workspace()],
            attention: [item("agent:n", .agentWaiting(tool: .claudeCode, session: "n"))],
            sessions: [MF.Session(id: "w", state: .working).make()])
        #expect(
            builder(state).rows(.inbox).map(\.id) == [
                "attention:agent:n", "section:agents", "agent:w", "section:workspaces", "workspace:default",
            ])
    }

    // MARK: Activity

    @Test func emptyActivitySaysNothingNew() {
        #expect(builder(MenuPanelState()).rows(.activity).map(\.title) == ["Nothing new"])
    }

    @Test func activityRowsOpenTheirPageElseTheAgentElseTheRepository() throws {
        let url = try #require(URL(string: "https://github.com/owner/app/pull/7"))
        let events = [
            FeedEvent(
                id: "1", kind: .pullRequestOpened, repository: MF.repository, repositoryName: "app",
                title: "octo opened #7", detail: "Add things", date: MF.now.addingTimeInterval(-30), url: url,
                sessionID: nil),
            FeedEvent(
                id: "2", kind: .agentFinished, repository: MF.repository, repositoryName: "app",
                title: "Claude Code finished", detail: "", date: MF.now.addingTimeInterval(-2 * 86_400), url: nil,
                sessionID: "s"),
            FeedEvent(
                id: "3", kind: .checksFailed, repository: MF.site, repositoryName: "site", title: "Checks failed",
                detail: "main", date: MF.now, url: nil, sessionID: nil),
        ]
        let rows = builder(MenuPanelState(feed: events)).rows(.activity)
        #expect(rows.map(\.action) == [.openURL(url), .reveal("s"), .showRepository(MF.site)])
        #expect(rows.allSatisfy { $0.kind == .item && $0.height == 44 })
        #expect(rows[0].lead == .symbol("arrow.triangle.pull", .accentText))
        #expect(rows[0].suffix == "app")
        #expect(rows[0].hoverChip?.action == .copy(url.absoluteString))
        #expect(rows[0].label.hasPrefix("octo opened #7, app, Add things"))
        #expect(rows[1].subtitle == nil)
        #expect(rows[1].hoverChip == nil)
    }

    @Test func homeIsTheRepositoryElseTheCheckoutElseTheWorkingDirectory() {
        var session = MF.Session(id: "a", state: .idle, checkout: worktree).make()
        #expect(PanelRowBuilder.home(session) == MF.repository)
        session.repositoryRoot = nil
        #expect(PanelRowBuilder.home(session) == worktree)
        session.checkoutRoot = nil
        session.workingDirectory = MF.site
        #expect(PanelRowBuilder.home(session) == MF.site)
    }
}

extension AgentSummary {
    fileprivate static func with(done: Int) -> Self {
        var summary = Self()
        summary.done = done
        return summary
    }
}
