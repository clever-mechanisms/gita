import AppKit
import Foundation
import Testing
import os

@testable import GitaCore
@testable import GitaUI

/// The agent monitor over a fake environment: scans, checkouts, hook events, Orca titles and settings are all
/// injected, so no process table, socket, home folder or Orca CLI is read.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentsMonitorTests {
    nonisolated static let repository = URL(fileURLWithPath: "/Users/u/projects/app", isDirectory: true)
    nonisolated static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// The fake system the monitor reads, and what it was asked.
    final class World: Sendable {
        let samples = OSAllocatedUnfairLock<[AgentProcessSample]>(initialState: [])
        let hook = OSAllocatedUnfairLock<(@Sendable (AgentHookEvent) -> Void)?>(initialState: nil)
        let orcaAsked = AgentsEvents<URL>()
        let scans = AgentsEvents<Void>()

        func set(_ samples: [AgentProcessSample]) { self.samples.withLock { $0 = samples } }

        /// What the hook socket would deliver.
        func send(_ event: AgentHookEvent) { hook.withLock { $0 }?(event) }

        static func sample(
            _ pid: Int32, _ tool: AgentTool = .claudeCode, cwd: String = repository.path
        )
            -> AgentProcessSample
        {
            AgentProcessSample(
                tool: tool, pid: pid, parentAgentPID: nil, workingDirectory: cwd, startedAt: start, cpuSeconds: 0,
                isService: false)
        }
    }

    struct Fixture {
        let world: World
        let sandbox: AgentsSandbox
        let monitor: AgentMonitor
        let published: AgentsEvents<[AgentSession]>
        let revealed: AgentsEvents<String>
    }

    /// `orcaGate`, when given, holds each Orca read until the test yields to it.
    static func fixture(
        orcaTitle: String? = nil, orcaState: AgentState? = nil, orcaGate: AgentsEvents<Void>? = nil
    ) throws -> Fixture {
        let sandbox = try AgentsSandbox("Agents")
        let world = World()
        let revealed = AgentsEvents<String>()
        var environment = AgentMonitorEnvironment()
        environment.scan = {
            world.scans.yield(())
            return world.samples.withLock { $0 }
        }
        environment.resolve = { directory, _ in
            directory.hasPrefix(repository.path)
                ? AgentCheckout(
                    checkoutRoot: repository, repositoryRoot: repository,
                    gitDirectory: repository.appendingPathComponent(".git"), branch: "main")
                : nil
        }
        environment.listen = { handler in
            world.hook.withLock { $0 = handler }
            return nil
        }
        environment.allowedRoots = { [repository.path] }
        environment.orcaSessions = { root in
            world.orcaAsked.yield(root)
            if let orcaGate { _ = await orcaGate.next() }
            guard orcaTitle != nil || orcaState != nil else { return [] }
            return [
                AgentMonitorEnvironment.OrcaSession(
                    path: repository.path, title: orcaTitle, tool: .claudeCode, state: orcaState)
            ]
        }
        environment.orcaRunning = { true }
        environment.defaults = sandbox.defaults
        environment.home = sandbox.folder
        environment.helpers = sandbox.folder.appendingPathComponent("Helpers", isDirectory: true)
        environment.isInstalledCopy = { true }
        environment.uptime = { 100 }
        environment.now = { start }
        environment.revealer = AgentHostRevealer(
            switchOrcaTerminal: { checkout, _ in revealed.yield(checkout.path) },
            lineage: { [$0] }, executablePath: { _ in "/Applications/Orca.app/Contents/MacOS/orca-terminal-host" },
            app: { _ in nil }, activate: { _ in false }, activateOrca: { true })
        let monitor = AgentMonitor(environment: environment)
        return Fixture(
            world: world, sandbox: sandbox, monitor: monitor, published: AgentsEvents(), revealed: revealed)
    }

    /// Starts observing, then waits for a published list that matches.
    @discardableResult
    static func observe(_ fixture: Fixture) -> UUID {
        let published = fixture.published
        return fixture.monitor.observe { published.yield($0) }
    }

    @Test func aScannedAgentBecomesASessionInItsRepository() async throws {
        let fixture = try Self.fixture()
        fixture.world.set([World.sample(100), World.sample(200, cwd: "/elsewhere")])
        let id = Self.observe(fixture)
        let sessions = await fixture.published.next { $0.count == 2 }
        #expect(sessions?.first { $0.pid == 100 }?.repositoryRoot == Self.repository)
        #expect(fixture.monitor.isRunning)
        #expect(fixture.monitor.sessions(inRepository: Self.repository).map(\.pid) == [100])
        #expect(fixture.monitor.summary(forRepository: Self.repository).idle + fixture.monitor.summary.idle >= 1)
        fixture.monitor.removeObserver(id)
        fixture.monitor.start()
        #expect(fixture.monitor.isRunning)
    }

    @Test func hookEventsUpdateTheSessionAtOnce() async throws {
        let fixture = try Self.fixture()
        fixture.world.set([World.sample(100)])
        Self.observe(fixture)
        _ = await fixture.published.next { !$0.isEmpty }
        fixture.world.send(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "a", pids: [101, 100]))
        #expect(await fixture.published.next()?.first?.state == .working)
        fixture.world.send(AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "a", pids: [101, 100]))
        let done = await fixture.published.next()
        #expect(done?.first?.state == .done)
        #expect(done?.first?.unseen == true)
        fixture.monitor.markSeen(repository: Self.repository)
        #expect(await fixture.published.next()?.first?.unseen == false)
        fixture.monitor.markSeen(repository: Self.repository)
        fixture.monitor.handle(AgentHookEvent(tool: .claudeCode, event: "Unknown", pids: [100]), retry: true)
        fixture.world.send(AgentHookEvent(tool: .claudeCode, event: "SessionEnd", sessionID: "a", pids: [101, 100]))
        #expect(await fixture.published.next()?.isEmpty == true)
    }

    @Test func aHookFromAnUnseenProcessIsOfferedAgainAfterTheNextScan() async throws {
        let fixture = try Self.fixture()
        Self.observe(fixture)
        _ = await fixture.world.scans.next()
        fixture.monitor.handle(
            AgentHookEvent(
                tool: .codex, event: "notify", sessionID: "s", cwd: Self.repository.path + "/sub",
                kind: "agent-turn-complete", pids: [700]),
            retry: true)
        let created = await fixture.published.next { !$0.isEmpty }
        #expect(created?.first?.tool == .codex)
        let resolved = await fixture.published.next { $0.first?.repositoryRoot != nil }
        #expect(resolved?.first?.checkoutRoot == Self.repository)
    }

    @Test func turningADetectorOffDropsItsSessions() async throws {
        let fixture = try Self.fixture()
        fixture.world.set([World.sample(100), World.sample(300, .codex)])
        Self.observe(fixture)
        _ = await fixture.published.next { $0.count == 2 }
        Preference.detectCodex.set(false, fixture.sandbox.defaults)
        #expect(await fixture.published.next()?.map(\.tool) == [.claudeCode])
        // Other preferences leave the scan alone.
        Preference.showsAvatars.set(true, fixture.sandbox.defaults)
    }

    @Test func orcaTitlesNameTheSessionsInTheirCheckoutWhenOrcaIsOn() async throws {
        let fixture = try Self.fixture(orcaTitle: "Fix the login")
        fixture.world.set([World.sample(100)])
        Self.observe(fixture)
        _ = await fixture.published.next { !$0.isEmpty }
        fixture.monitor.setVisible(true)
        fixture.monitor.setVisible(true)
        Preference.useOrca.set(true, fixture.sandbox.defaults)
        #expect(await fixture.world.orcaAsked.next() == Self.repository)
        #expect(await fixture.published.next { $0.first?.title != nil }?.first?.title == "Fix the login")
        fixture.monitor.setVisible(false)
        Preference.useOrca.set(false, fixture.sandbox.defaults)
        #expect(await fixture.published.next()?.first?.title == nil)
    }

    @Test func orcaReportsTheStateOfASessionWithoutHooks() async throws {
        let fixture = try Self.fixture(orcaState: .needsInput)
        fixture.world.set([World.sample(100)])
        Self.observe(fixture)
        _ = await fixture.published.next { !$0.isEmpty }
        Preference.useOrca.set(true, fixture.sandbox.defaults)
        fixture.monitor.setVisible(true)
        let session = await fixture.published.next { $0.first?.state == .needsInput }?.first
        #expect(session?.evidence == .orca)
    }

    @Test func turningOrcaOffDropsTheReadInFlight() async throws {
        let gate = AgentsEvents<Void>()
        let fixture = try Self.fixture(orcaState: .needsInput, orcaGate: gate)
        fixture.world.set([World.sample(100)])
        Self.observe(fixture)
        _ = await fixture.published.next { !$0.isEmpty }
        Preference.useOrca.set(true, fixture.sandbox.defaults)
        fixture.monitor.setVisible(true)
        _ = await fixture.world.orcaAsked.next()
        Preference.useOrca.set(false, fixture.sandbox.defaults)
        gate.yield(())
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.monitor.sessions.first?.state != .needsInput)
        #expect(fixture.monitor.sessions.first?.evidence != .orca)
        // Turning it on again reads at once: the dropped read no longer holds the slot.
        Preference.useOrca.set(true, fixture.sandbox.defaults)
        #expect(await fixture.world.orcaAsked.next() == Self.repository)
        gate.yield(())
        #expect(await fixture.published.next { $0.first?.state == .needsInput }?.first?.evidence == .orca)
    }

    @Test func revealGoesThroughTheHostsRevealer() async throws {
        let fixture = try Self.fixture()
        fixture.world.set([World.sample(100)])
        Self.observe(fixture)
        let session = try #require(await fixture.published.next { !$0.isEmpty }?.first)
        #expect(fixture.monitor.host(of: session) == .orca)
        #expect(fixture.monitor.reveal(session))
        #expect(await fixture.revealed.next() == Self.repository.path)
        #expect(AgentMonitor.orcaBundleID == BrandMarks.orca)
    }

    @Test func aStoppedMonitorIgnoresVisibilityAndHooks() throws {
        let fixture = try Self.fixture()
        fixture.monitor.setVisible(true)
        fixture.monitor.scanNow()
        fixture.monitor.handle(AgentHookEvent(tool: .claudeCode, event: "Stop", pids: [100]), retry: true)
        #expect(!fixture.monitor.isRunning)
        #expect(fixture.monitor.sessions.isEmpty)
    }

    @Test func hooksInstallIntoTheInjectedHomeOnlyWithTheHelperPresent() throws {
        let fixture = try Self.fixture()
        let monitor = fixture.monitor
        #expect(monitor.hookStatus(.opencode) != .notInstalled)
        try fixture.sandbox.directory(".claude")
        if case .unavailable = monitor.hookStatus(.claudeCode) {} else { Issue.record("helper missing") }
        #expect(throws: AgentHookError.helperMissing) { try monitor.installHooks(.claudeCode) }
        try fixture.sandbox.executable("Helpers/\(AgentHookInstaller.helperName)")
        #expect(monitor.hookStatus(.claudeCode) == .notInstalled)
        try monitor.installHooks(.claudeCode)
        #expect(monitor.hookStatus(.claudeCode) == .installed)
        try AgentHookInstaller(home: fixture.sandbox.folder, helperPath: "/old/gita-agent").install(.claudeCode)
        #expect(monitor.hookStatus(.claudeCode) == .needsUpdate)
        try monitor.removeHooks(.claudeCode)
        #expect(monitor.hookStatus(.claudeCode) == .notInstalled)
    }

    @Test func aCopyOutsideApplicationsRefusesToInstallHooks() throws {
        let sandbox = try AgentsSandbox("AgentsLocation")
        try sandbox.directory(".claude")
        try sandbox.executable("Helpers/\(AgentHookInstaller.helperName)")
        var environment = AgentMonitorEnvironment()
        environment.listen = { _ in nil }
        environment.defaults = sandbox.defaults
        environment.home = sandbox.folder
        environment.helpers = sandbox.folder.appendingPathComponent("Helpers", isDirectory: true)
        environment.isInstalledCopy = { false }
        let monitor = AgentMonitor(environment: environment)
        let reason = AgentHookLocationError.notInstalledCopy.localizedDescription
        #expect(monitor.hookStatus(.claudeCode) == .unavailable(reason))
        #expect(throws: AgentHookLocationError.notInstalledCopy) { try monitor.installHooks(.claudeCode) }
        let settings = sandbox.folder.appendingPathComponent(".claude/settings.json")
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }
}
