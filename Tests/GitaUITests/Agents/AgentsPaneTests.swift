import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The Worktrees & Agents pane: grouping and filtering (pure), an opened row's facts, and the pane itself hosted
/// headlessly with its own choices and defaults.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentsPaneTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let app = URL(fileURLWithPath: "/Users/u/projects/app", isDirectory: true)
    private static let zeta = URL(fileURLWithPath: "/Users/u/projects/zeta", isDirectory: true)
    private static let beta = URL(fileURLWithPath: "/Users/u/projects/beta", isDirectory: true)

    private static func session(
        _ id: String, _ state: AgentState, root: URL = app, title: String? = nil, evidence: AgentEvidence = .hook,
        subagent: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id, tool: .claudeCode, pid: nil, workingDirectory: root, checkoutRoot: root, repositoryRoot: root,
            branch: "main", state: state, stateSince: now, startedAt: now.addingTimeInterval(-125), evidence: evidence,
            title: title, isSubagent: subagent)
    }

    private static func row(
        _ id: String, root: URL = app, session: AgentSession? = nil, tree: String = "", branch: String = "main",
        current: Bool = false
    ) -> AgentsPaneView.Row {
        AgentsPaneView.Row(
            id: id, session: session, repositoryName: root.lastPathComponent, repositoryRoot: root,
            checkoutPath: root.appendingPathComponent(tree).path, treeName: tree, branch: branch,
            isCurrentRepository: current)
    }

    private static var rows: [AgentsPaneView.Row] {
        [
            row("z1", root: zeta, session: session("w", .needsInput, root: zeta)),
            row("b1", root: beta, session: session("n", .working, root: beta)),
            row("a1", current: true),
            row("a2", session: session("d", .done), tree: "feature", branch: "feature/login", current: true),
        ]
    }

    // MARK: Pure parts

    @Test func theOpenRepositoryComesFirstThenTheOthersByStatusOrName() {
        let byStatus = AgentsPaneLayout.groups(Self.rows, filter: .all, query: "", order: .status)
        #expect(byStatus.map(\.title) == ["app", "zeta", "beta"])
        #expect(byStatus.first?.isCurrent == true)
        #expect(byStatus.first?.rows.map(\.id) == ["a2", "a1"])
        let byName = AgentsPaneLayout.groups(Self.rows, filter: .all, query: "", order: .name)
        #expect(byName.map(\.title) == ["app", "beta", "zeta"])
        let working = AgentsPaneLayout.groups(Self.rows, filter: .state(.working), query: "", order: .status)
        #expect(working.map(\.title) == ["beta"])
        #expect(AgentsPaneLayout.groups(Self.rows, filter: .noAgent, query: "", order: .name).map(\.title) == ["app"])
        #expect(AgentsPaneLayout.groups(Self.rows, filter: .all, query: "login", order: .name).first?.rows.count == 1)
        #expect(AgentsPaneLayout.groups(Self.rows, filter: .all, query: "nothing", order: .name).isEmpty)
    }

    @Test func stateFiltersCountAndNameTheirRows() {
        #expect(AgentsPaneView.StateFilter.choices.count == 6)
        #expect(AgentsPaneView.StateFilter.all.count(in: Self.rows) == 4)
        #expect(AgentsPaneView.StateFilter.noAgent.count(in: Self.rows) == 1)
        #expect(AgentsPaneView.StateFilter.state(.done).count(in: Self.rows) == 1)
        let titles = Set(AgentsPaneView.StateFilter.choices.map(\.title))
        #expect(titles.count == 6)
        #expect(Self.rows[3].name == "feature")
        #expect(Self.rows[2].name == "app")
        #expect(Self.rows[2].urgency == AgentState.byUrgency.count)
    }

    @Test func theWorkingChipTurnsOneMarkPerAgentTool() {
        var codex = Self.session("x", .working)
        codex.tool = .codex
        var gemini = Self.session("g", .done)
        gemini.tool = .gemini
        let marks = AgentsPaneView.workingMarks([
            codex, Self.session("c", .working), Self.session("s", .working, subagent: true), gemini,
        ])
        #expect(marks.map(\.tool) == [.claudeCode, .codex])
        #expect(marks.allSatisfy { $0.state == .working })
        #expect(AgentsPaneView.workingMarks([Self.session("d", .done)]).isEmpty)
    }

    @Test func stateWordsColoursAndUrgency() {
        #expect(Set(AgentState.byUrgency.map(\.localizedTitle)).count == 4)
        #expect(Set(AgentState.byUrgency.map(\.panelColor)).count == 4)
        for state in AgentState.byUrgency { _ = state.textColor }
        #expect(AgentState.urgency(.needsInput) == 0)
        #expect(AgentState.urgency(nil) == 4)
    }

    @Test func anOpenedRowListsTheSessionTheCheckoutAndItsSignals() {
        var row = Self.row(
            "a2", session: Self.session("d", .done, title: "Fix login", evidence: .orca), tree: "feature")
        row.subagents = [Self.session("s1", .working, subagent: true), Self.session("s2", .idle, subagent: true)]
        row.pullRequest = ProviderItem(
            id: "pr", provider: .github, category: "PR", title: "Login", state: .success, kind: .pullRequest,
            pullRequest: PullRequestSummary(number: 7, lifecycle: .open, isDraft: false))
        row.checks = [
            ProviderItem(id: "c1", provider: .github, category: "CI", title: "t", state: .success, kind: .check),
            ProviderItem(id: "c2", provider: .vercel, category: "x", title: "t", state: .failure, kind: .deployment),
        ]
        row.preview = ProviderItem(id: "p", provider: .vercel, category: "x", title: "t", state: .success)
        let facts = PaneFacts.make(row, now: Self.now)
        #expect(facts.first?.value == DeckFormat.duration(125))
        #expect(facts.first { $0.isPath }?.value == Self.app.path)
        #expect(facts.contains { $0.value.hasPrefix("2 · ") })
        #expect(facts.contains { $0.value == "Fix login" })
        #expect(facts.contains { $0.value == "Orca" })
        #expect(facts.contains { $0.value.contains("Vercel") })
        #expect(facts.count == 8)
        row.checks = [row.checks[0]]
        row.preview?.state = .running
        #expect(PaneFacts.make(row, now: Self.now).contains { $0.value == "✓ CI" })
        let plain = PaneFacts.make(Self.row("a1"), now: Self.now)
        #expect(plain.map(\.isPath) == [true])
        #expect(PaneFacts.evidence(.hook) != PaneFacts.evidence(.process))
        #expect(PaneFacts.worst([]) == nil)
    }

    // MARK: The pane

    private static func hosted(_ defaults: UserDefaults) -> (AgentsPaneView, NSWindow) {
        let pane = AgentsPaneView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 600), choices: AgentsPaneChoices(defaults: defaults))
        let controller = NSViewController()
        controller.view = pane
        return (pane, UITestSupport.host(controller, size: NSSize(width: 320, height: 600)))
    }

    private static func listed(_ pane: AgentsPaneView) -> (headers: Int, rows: [PaneRowView]) {
        let views = pane.list.arrangedSubviews
        return (views.filter { $0 is PaneGroupHeader }.count, views.compactMap { $0 as? PaneRowView })
    }

    @Test func thePaneListsGroupsAndFiltersByChip() throws {
        let sandbox = try AgentsSandbox("Agents")
        let (pane, window) = Self.hosted(sandbox.defaults)
        defer { window.close() }
        #expect(pane.emptyLabel.isHidden == false || pane.rows.isEmpty)
        pane.update(rows: Self.rows)
        pane.update(rows: Self.rows)
        #expect(Self.listed(pane).headers == 3)
        #expect(Self.listed(pane).rows.count == 4)
        #expect(pane.emptyLabel.isHidden)
        pane.choose(.state(.working))
        #expect(Self.listed(pane).rows.map(\.row.id) == ["b1"])
        pane.choose(.state(.working))
        #expect(Self.listed(pane).rows.count == 4)
        pane.filter.stringValue = "nothing"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!pane.emptyLabel.isHidden)
        pane.canCreateWorktree = true
        window.layoutIfNeeded()
        UITestSupport.render(pane)
    }

    @Test func expandingARowShowsItsDetailAndItsActions() throws {
        let sandbox = try AgentsSandbox("Agents")
        let (pane, window) = Self.hosted(sandbox.defaults)
        defer { window.close() }
        var revealed: [String] = []
        var shown: [String] = []
        var opened: [URL] = []
        pane.onReveal = { revealed.append($0.id) }
        pane.onShowInHistory = { shown.append($0.id) }
        pane.onOpenCheckout = { opened.append($0) }
        pane.update(rows: Self.rows)
        pane.choose(.noAgent)
        pane.filter.stringValue = "zeta"
        pane.expand(sessionID: "w")
        #expect(pane.expanded == "z1")
        #expect(pane.choices.stateFilter == .all)
        #expect(pane.filter.stringValue.isEmpty)
        pane.expand(sessionID: nil)
        pane.expand(sessionID: "missing")
        #expect(pane.expanded == "z1")
        window.layoutIfNeeded()
        let row = try #require(Self.listed(pane).rows.first { $0.row.id == "z1" })
        UITestSupport.render(row)
        #expect(row.acceptsClick(at: NSPoint(x: 5, y: 5)))
        #expect(!row.acceptsClick(at: NSPoint(x: 5, y: row.bounds.height - 2)))
        row.onDoubleClick?()
        #expect(revealed == ["w"])
        let buttons = Self.buttons(in: row)
        buttons.first { $0.accessibilityLabel() == String(localized: "Show in History") }?.onClick?()
        buttons.first { $0.accessibilityLabel() == String(localized: "Open in New Tab") }?.onClick?()
        #expect(shown == ["z1"])
        #expect(opened == [Self.zeta])
        row.onClick?()
        #expect(pane.expanded == nil)
        pane.toggle("a1")
        #expect(pane.expanded == "a1")
        window.layoutIfNeeded()
    }

    @Test func theSortMenuStoresTheOrderInTheInjectedDefaults() throws {
        let sandbox = try AgentsSandbox("Agents")
        let (pane, window) = Self.hosted(sandbox.defaults)
        defer { window.close() }
        pane.update(rows: Self.rows)
        let menu = pane.orderMenu()
        #expect(menu.items.map(\.state) == [.on, .off])
        menu.performActionForItem(at: 1)
        #expect(pane.choices.order == .name)
        #expect(Preference.agentsPaneOrder.string(sandbox.defaults) == RepositoryListOrder.name.rawValue)
        #expect(pane.orderMenu().items.map(\.state) == [.off, .on])
        #expect(AgentsPaneChoices(defaults: sandbox.defaults).order == .name)
        Preference.agentsPaneOrder.set(RepositoryListOrder.recent.rawValue, sandbox.defaults)
        #expect(AgentsPaneChoices(defaults: sandbox.defaults).order == .status)
    }

    @Test func rowsWithoutAnAgentSayWhy() throws {
        var worktree = Self.row("t", tree: "spike", branch: "spike")
        worktree.isMainCheckout = false
        worktree.ahead = 2
        worktree.isOpenHere = true
        for row in [Self.row("m"), worktree] {
            let view = PaneRowView(row: row, expanded: true, now: Self.now)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
            view.layoutSubtreeIfNeeded()
            UITestSupport.render(view)
            #expect(view.accessibilityLabel()?.isEmpty == false)
            view.onDoubleClick?()
        }
        var withSubagents = Self.row("s", session: Self.session("w", .working))
        withSubagents.subagents = [Self.session("c", .working, subagent: true)]
        let view = PaneRowView(row: withSubagents, expanded: false, now: Self.now)
        #expect(view.accessibilityLabel()?.contains("main") == true)
    }

    private static func buttons(in view: NSView) -> [PartsButton] {
        view.subviews.flatMap { ($0 as? PartsButton).map { [$0] } ?? buttons(in: $0) }
    }
}
