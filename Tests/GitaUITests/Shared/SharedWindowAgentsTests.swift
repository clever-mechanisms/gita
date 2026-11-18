import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// A `WindowAgents` over a monitor that scans nothing, opens no socket and reads a scratch defaults suite.
@MainActor
final class SharedAgentsHarness {
    let suite: String
    let center = NotificationCenter()
    let agents: WindowAgents
    let monitor: AgentMonitor
    var posts = 0
    private var observer: NSObjectProtocol?

    init() {
        let (defaults, name) = SharedFixtures.scratchDefaults()
        suite = name
        var environment = AgentMonitorEnvironment()
        environment.scan = { [] }
        environment.resolve = { _, _ in nil }
        environment.listen = { _ in nil }
        environment.allowedRoots = { [] }
        environment.orcaSessions = { _ in [] }
        environment.defaults = defaults
        monitor = AgentMonitor(environment: environment)
        agents = WindowAgents(monitor: monitor, center: center)
        observer = center.addObserver(forName: WindowAgents.didChange, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.posts += 1 }
        }
    }
    func tearDown() {
        if let observer { center.removeObserver(observer) }
        SharedFixtures.remove(suite)
    }
}

@MainActor
@Suite struct SharedWindowAgentsTests {
    private let root = URL(fileURLWithPath: "/tmp/GitaUITests-shared-repo")
    private var worktree: URL { URL(fileURLWithPath: "/tmp/GitaUITests-shared-worktree") }

    @Test func publishOrdersSessionsAndPostsOnlyOnChange() {
        let harness = SharedAgentsHarness()
        defer { harness.tearDown() }
        let idle = SharedFixtures.session("idle", state: .idle, since: -10)
        let older = SharedFixtures.session("older", since: -100)
        let newer = SharedFixtures.session("newer", since: -5)
        let waiting = SharedFixtures.session("waiting", state: .needsInput, since: -500)
        harness.agents.publish([idle, older, newer, waiting])
        harness.agents.publish([waiting, newer, older, idle])
        #expect(harness.agents.sessions.map(\.id) == ["waiting", "newer", "older", "idle"])
        #expect(harness.posts == 1)
        harness.agents.start()
        harness.agents.start()
        #expect(harness.agents.sessions.isEmpty, "the idle monitor reports nobody")
        #expect(harness.posts == 2)
    }

    @Test func queriesMatchRepositoryCheckoutAndWorktrees() {
        let harness = SharedAgentsHarness()
        defer { harness.tearDown() }
        let inRepository = SharedFixtures.session("repo", checkout: root, repository: root)
        let inWorktree = SharedFixtures.session("tree", checkout: worktree)
        let elsewhere = SharedFixtures.session("far", checkout: URL(fileURLWithPath: "/tmp/GitaUITests-far"))
        var floating = SharedFixtures.session("float")
        floating.workingDirectory = URL(fileURLWithPath: "/")
        harness.agents.publish([inRepository, inWorktree, elsewhere, floating])
        let found = harness.agents.sessions(repository: root, worktreePaths: [worktree.path]).map(\.id)
        #expect(Set(found) == ["repo", "tree"])
        #expect(harness.agents.sessions(repository: root).map(\.id) == ["repo"])
        #expect(harness.agents.sessions(checkout: worktree).map(\.id) == ["tree"])
        #expect(WindowAgents.key(nil) == nil)
        #expect(WindowAgents.key(root) == root.standardizedFileURL.resolvingSymlinksInPath().path)
        harness.agents.markSeen(repository: root)
        #expect(harness.agents.summary.working == 4)
    }

    @Test func subagentsFoldIntoTheirParentInTheSameCheckout() {
        let parent = SharedFixtures.session("lead", checkout: root)
        let child = SharedFixtures.session("child", checkout: root, subagentOf: "lead")
        let waitingChild = SharedFixtures.session(
            "asks", state: .needsInput, checkout: root, subagentOf: "lead")
        let orphan = SharedFixtures.session("orphan", checkout: root, subagentOf: "gone")
        let away = SharedFixtures.session("away", checkout: worktree, subagentOf: "lead")
        let all = [parent, child, waitingChild, orphan, away]
        #expect(WindowAgents.folds(child, in: all))
        #expect(!WindowAgents.folds(waitingChild, in: all))
        #expect(!WindowAgents.folds(orphan, in: all))
        #expect(!WindowAgents.folds(away, in: all))
        #expect(!WindowAgents.folds(parent, in: all))
        #expect(WindowAgents.subagents(of: parent, in: all).map(\.id) == ["child", "asks", "away"])
        let harness = SharedAgentsHarness()
        defer { harness.tearDown() }
        harness.agents.publish(all)
        #expect(harness.agents.summary.working + harness.agents.summary.needsInput == 4)
    }

    @Test func crowdsLeadWithTheFirstTopLevelAgent() throws {
        #expect(WindowAgents.crowd([]) == nil)
        let child = SharedFixtures.session("child", subagentOf: "none")
        let lead = SharedFixtures.session("lead", state: .done)
        let other = SharedFixtures.session("other", state: .needsInput)
        let crowd = try #require(WindowAgents.crowd([child, lead, other]))
        #expect(crowd.lead.id == "lead")
        #expect(crowd.others == 1)
        #expect(crowd.subagents == 1)
        #expect(crowd.state == .needsInput)
        #expect(try #require(WindowAgents.crowd([child])).lead.id == "child")
    }

    @Test func revealTitleFallsBackWithoutAKnownApp() {
        let harness = SharedAgentsHarness()
        defer { harness.tearDown() }
        let session = SharedFixtures.session("lead")
        #expect(harness.agents.hostApp(session) == nil)
        #expect(harness.agents.revealTitle(session) == String(localized: "Bring Terminal Forward"))
    }
}

@MainActor
@Suite struct SharedWindowAgentsTextTests {
    private let now = SharedFixtures.now

    private func crowd(_ lead: AgentSession, others: Int, subagents: Int, state: AgentState) -> WindowAgents.Crowd {
        WindowAgents.Crowd(lead: lead, others: others, subagents: subagents, state: state)
    }

    @Test func crowdLinesNameTheShape() {
        let lead = SharedFixtures.session("lead", state: .working)
        let name = AgentTool.claudeCode.displayName
        #expect(WindowAgents.crowdLine(crowd(lead, others: 0, subagents: 0, state: .working)).hasPrefix(name))
        #expect(
            WindowAgents.crowdLine(crowd(lead, others: 0, subagents: 0, state: .working), naming: false)
                == String(localized: "Working"))
        let sub = SharedFixtures.session("sub", subagentOf: "none")
        #expect(
            WindowAgents.crowdLine(crowd(sub, others: 0, subagents: 0, state: .working), naming: false)
                .hasPrefix(String(localized: "Subagent")))
        let waiting = WindowAgents.crowdLine(crowd(lead, others: 2, subagents: 0, state: .needsInput))
        #expect(waiting == String(localized: "Needs input") + " · " + String(localized: "\(3) agents"))
        let waitingSub = WindowAgents.crowdLine(crowd(lead, others: 0, subagents: 4, state: .needsInput))
        #expect(waitingSub.hasSuffix(String(localized: "\(4) subagents")))
        let withSubs = WindowAgents.crowdLine(crowd(lead, others: 0, subagents: 12, state: .working))
        #expect(withSubs == name + " · " + String(localized: "\(12) subagents"))
        let unnamed = WindowAgents.crowdLine(crowd(lead, others: 0, subagents: 12, state: .done), naming: false)
        #expect(unnamed.hasPrefix(String(localized: "Done")))
        let several = WindowAgents.crowdLine(crowd(lead, others: 2, subagents: 0, state: .working))
        #expect(several == String(localized: "\(3) agents"))
        let severalSubs = WindowAgents.crowdLine(crowd(lead, others: 2, subagents: 5, state: .working))
        #expect(severalSubs == String(localized: "\(3) agents") + " · " + String(localized: "\(5) subagents"))
    }

    @Test func stateWordsColoursAndCounts() {
        let states: [AgentState] = [.working, .needsInput, .done, .idle]
        #expect(Set(states.map(WindowAgents.stateTitle)).count == 4)
        #expect(WindowAgents.stateColor(.working) === Theme.accentText)
        #expect(WindowAgents.stateColor(.needsInput) === Theme.needsInputText)
        #expect(WindowAgents.stateColor(.done) === Theme.success)
        #expect(WindowAgents.stateColor(.idle) === Theme.secondaryText)
        let sessions = [
            SharedFixtures.session("a"), SharedFixtures.session("b"), SharedFixtures.session("c", state: .idle),
        ]
        #expect(
            WindowAgents.stateCounts(sessions)
                == String(localized: "Working") + " 2 · " + String(localized: "Idle") + " 1")
        #expect(WindowAgents.stateCounts([]).isEmpty)
    }

    @Test func linesCarryNamesStatesAndDurations() {
        let idle = SharedFixtures.session("idle", state: .idle, since: -3_600)
        let name = AgentTool.claudeCode.displayName
        #expect(WindowAgents.stateLine(idle, now: now) == String(localized: "Idle") + " " + DeckFormat.duration(3_600))
        #expect(WindowAgents.line(idle, now: now) == name + " · " + WindowAgents.stateLine(idle, now: now))
        #expect(WindowAgents.menuLine(idle, now: now) == WindowAgents.line(idle, now: now))
        var started = SharedFixtures.session("run")
        started.startedAt = now.addingTimeInterval(-120)
        #expect(WindowAgents.menuLine(started, now: now).hasSuffix(" · " + DeckFormat.duration(120)))
        #expect(WindowAgents.menuLine(SharedFixtures.session("plain"), now: now) == name + " · Working")
        let sub = SharedFixtures.session("sub", state: .done, subagentOf: "none")
        #expect(WindowAgents.title(sub) == String(localized: "Subagent"))
        #expect(WindowAgents.markedLine(sub, now: now) == WindowAgents.line(sub, now: now))
        let top = SharedFixtures.session("top", state: .done)
        #expect(WindowAgents.markedLine(top, now: now) == String(localized: "Done"))
    }
}
