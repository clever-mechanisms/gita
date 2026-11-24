import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 50_000)
}

@MainActor
private final class ScriptedRemoteRunner {
    var checkResult: (String) async throws -> RemoteDelta = { _ in RemoteDelta() }
    var fetchResult: (String) async throws -> Void = { _ in }
    private(set) var checkedRemotes: [String] = []
    private(set) var fetchedRemotes: [String] = []

    func resetCounts() {
        checkedRemotes.removeAll()
        fetchedRemotes.removeAll()
    }

    func check(_ remote: String) async throws -> RemoteDelta {
        checkedRemotes.append(remote)
        return try await checkResult(remote)
    }

    func fetch(_ remote: String) async throws {
        fetchedRemotes.append(remote)
        try await fetchResult(remote)
    }
}

@Suite("RemoteMonitor scheduling, concurrency, backoff, cancellation and AppModel integration")
@MainActor
struct ModelRemoteMonitorTests {
    private func makeMonitor(
        clock: FakeClock, runner: ScriptedRemoteRunner, staggers: AppBox<[Int]>? = nil
    ) -> RemoteMonitor {
        var env = RemoteMonitorEnvironment()
        env.now = { clock.now }
        env.jitter = { 0 }
        env.staggerDelay = { index in
            staggers?.value.append(index)
            return 0
        }
        env.sleep = { _ in }
        env.isLowPowerMode = { false }
        env.checkRemote = { _, remote, _, _, _, _ in try await runner.check(remote) }
        env.backgroundFetch = { _, remote in try await runner.fetch(remote) }
        env.startsSystemMonitors = false
        return RemoteMonitor(environment: env)
    }

    private func makeSnapshot(
        root: URL, remoteURLs: [String: String] = ["origin": "https://example.invalid/r.git"]
    ) -> RepositorySnapshot {
        var snapshot = RepositorySnapshot(
            root: root, branch: "main", head: String(repeating: "a", count: 40), changes: [], commits: [],
            references: [], worktrees: [], stashes: [], remoteURL: remoteURLs["origin"],
            gitDirectory: root.appendingPathComponent(".git"), commonGitDirectory: root.appendingPathComponent(".git"))
        snapshot.remoteURLs = remoteURLs
        return snapshot
    }

    @Test func tier1CheckRunsWithoutAutoFetchByDefaultAndAutoFetchRunsOnlyOnDelta() async throws {
        let harness = try ModelHarness()
        let clock = FakeClock()
        let script = ScriptedRemoteRunner()
        let monitor = makeMonitor(clock: clock, runner: script)
        let tip = RemoteTip(localOID: "a", remoteOID: "b")
        let movedDelta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): tip],
            currentUpstreamMoved: true, checkedAt: clock.now)
        script.checkResult = { _ in movedDelta }

        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url), defaults: harness.defaults)
        guard case .waiting = monitor.state(for: harness.url).phase else {
            Issue.record("Expected initial waiting state")
            return
        }

        monitor.tick()
        let checked = await eventually {
            script.checkedRemotes.count == 1 && !monitor.state(for: harness.url).isBusy
        }
        #expect(checked)
        #expect(script.fetchedRemotes.isEmpty)
        #expect(monitor.state(for: harness.url).last?.currentUpstreamMoved == true)

        Preference.remoteAutoFetch.set(true, harness.defaults)
        script.checkResult = { _ in RemoteDelta(checkedAt: clock.now) }
        monitor.checkNow(for: harness.url)
        #expect(await eventually { script.checkedRemotes.count == 2 && !monitor.state(for: harness.url).isBusy })
        #expect(script.fetchedRemotes.isEmpty)

        script.checkResult = { _ in movedDelta }
        monitor.checkNow(for: harness.url)
        #expect(
            await eventually {
                script.fetchedRemotes == ["origin"] && !monitor.state(for: harness.url).isBusy
            })
        #expect(monitor.state(for: harness.url).last?.moved.isEmpty == true)
    }

    @Test func backoffAuthPauseAndManualResetBehaveCorrectly() async throws {
        let harness = try ModelHarness()
        let clock = FakeClock()
        let script = ScriptedRemoteRunner()
        let monitor = makeMonitor(clock: clock, runner: script)
        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url), defaults: harness.defaults)

        script.checkResult = { _ in throw RemoteCheckError(failure: .unreachable) }
        for expectedMinutes in [5.0, 10.0, 20.0] {
            monitor.checkNow(for: harness.url)
            #expect(await eventually { !monitor.state(for: harness.url).isBusy })
            guard case .backingOff(let until, .unreachable) = monitor.state(for: harness.url).phase else {
                Issue.record("Expected unreachable backoff")
                return
            }
            #expect(until.timeIntervalSince(clock.now) == expectedMinutes * 60)
            clock.now = until
        }

        script.checkResult = { _ in throw RemoteCheckError(failure: .authenticationRequired) }
        monitor.checkNow(for: harness.url)
        #expect(await eventually { !monitor.state(for: harness.url).isBusy })
        guard case .backingOff(_, .authenticationRequired) = monitor.state(for: harness.url).phase else {
            Issue.record("Expected auth pause")
            return
        }
        script.resetCounts()
        monitor.tick()
        #expect(script.checkedRemotes.isEmpty)

        monitor.didCompleteManualSync(for: harness.url, reenableAuth: false)
        guard case .backingOff(_, .authenticationRequired) = monitor.state(for: harness.url).phase else {
            Issue.record("Pull/Push should not re-enable auth pause")
            return
        }
        monitor.didCompleteManualSync(for: harness.url, reenableAuth: true)
        script.checkResult = { _ in RemoteDelta(checkedAt: clock.now) }
        monitor.checkNow(for: harness.url)
        #expect(
            await eventually {
                script.checkedRemotes == ["origin"] && !monitor.state(for: harness.url).isBusy
            })
    }

    @Test func concurrencyCapAndStaggerAndOfflineAndPendingCheckWork() async throws {
        let clock = FakeClock()
        let script = ScriptedRemoteRunner()
        let staggers = AppBox<[Int]>([])
        let monitor = makeMonitor(clock: clock, runner: script, staggers: staggers)

        let gate = AsyncGate()
        script.checkResult = { _ in
            await gate.wait()
            return RemoteDelta(checkedAt: clock.now)
        }
        let harnesses = try (0..<4).map { _ in try ModelHarness() }
        for harness in harnesses {
            monitor.register(
                model: harness.model, root: harness.url, service: GitService(root: harness.url),
                snapshot: makeSnapshot(root: harness.url), defaults: harness.defaults)
        }
        monitor.tick()
        #expect(monitor.inFlight.count == 2)
        #expect(staggers.value == [0, 1])

        // Requesting checkNow on an actively checking repo honors the pending check after completion.
        let busyHarness = try #require(harnesses.first { monitor.state(for: $0.url).isBusy })
        monitor.checkNow(for: busyHarness.url)
        await gate.open()
        #expect(
            await eventually {
                monitor.inFlight.isEmpty && staggers.value.count == 4 && script.checkedRemotes.count == 5
            })

        monitor.updateNetworkStatus(.offline)
        #expect(monitor.state(for: harnesses[0].url).statusSummary(now: clock.now) == String(localized: "Offline"))
        monitor.updateNetworkStatus(.online)
        #expect(await eventually { !monitor.state(for: harnesses[0].url).isBusy })
    }

    @Test func cancellingBackgroundFetchResetsStateAndPlainHTTPUrlRecoversWhenUpdated() async throws {
        let harness = try ModelHarness()
        let clock = FakeClock()
        let script = ScriptedRemoteRunner()
        let monitor = makeMonitor(clock: clock, runner: script)
        Preference.remoteAutoFetch.set(true, harness.defaults)

        let fetchGate = AsyncGate()
        let delta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): RemoteTip(localOID: "a", remoteOID: "b")],
            currentUpstreamMoved: true, checkedAt: clock.now)
        script.checkResult = { _ in delta }
        script.fetchResult = { _ in await fetchGate.wait() }

        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url), defaults: harness.defaults)
        monitor.checkNow(for: harness.url)
        #expect(await eventually { monitor.state(for: harness.url).isFetching })

        monitor.cancelBackgroundFetch(for: harness.url)
        #expect(!monitor.state(for: harness.url).isBusy)
        #expect(monitor.inFlight.isEmpty)
        await fetchGate.open()

        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url, remoteURLs: ["origin": "http://example.invalid/r.git"]),
            defaults: harness.defaults)
        monitor.checkNow(for: harness.url)
        #expect(
            await eventually {
                if case .backingOff(_, .unsupportedURL) = monitor.state(for: harness.url).phase { return true }
                return false
            })
        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url, remoteURLs: ["origin": "https://example.invalid/r.git"]),
            defaults: harness.defaults)
        #expect(monitor.statusLine(for: [harness.url], now: clock.now).contains(harness.url.lastPathComponent))
    }

    @Test func appModelIntegratesWithRealBareRemoteFixtureForTier1AndTier2() async throws {
        let harness = try ModelHarness()
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaBareModel-\(UUID().uuidString).git", isDirectory: true)
        let peer = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaPeerModel-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: peer)
        }
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try harness.repository.git("init", "--bare", "--initial-branch=main", bare.path)
        try harness.repository.git("remote", "add", "origin", bare.path)
        try harness.repository.git("push", "-u", "origin", "main")
        try harness.repository.git("clone", "--quiet", bare.path, peer.path)
        for (key, value) in [
            ("user.name", "Peer"), ("user.email", "peer@example.invalid"), ("commit.gpgsign", "false"),
        ] {
            try runGit(["config", key, value], at: peer)
        }
        try Data("b\n".utf8).write(to: peer.appendingPathComponent("b.txt"))
        try runGit(["add", "--all"], at: peer)
        try runGit(["commit", "--quiet", "-m", "Peer commit"], at: peer)
        try runGit(["push", "--quiet", "origin", "main"], at: peer)

        try await harness.open()
        defer { RemoteMonitor.shared.unregister(model: harness.model) }
        harness.model.checkRemotesNow()
        #expect(
            await eventually {
                harness.model.remoteDelta?.currentUpstreamMoved == true && !harness.model.remoteCheckState.isBusy
            })
        #expect(harness.model.snapshot?.behind == 0)

        Preference.remoteAutoFetch.set(true, harness.defaults)
        harness.model.checkRemotesNow()
        #expect(await eventually { harness.model.snapshot?.behind == 1 })
        #expect(harness.model.remoteDelta?.moved.isEmpty == true)
    }

    @Test func multiRemoteAutoFetchClearsCurrentUpstreamWhenOriginSucceedsAndUpstreamFails() async throws {
        let harness = try ModelHarness()
        let clock = FakeClock()
        let script = ScriptedRemoteRunner()
        let monitor = makeMonitor(clock: clock, runner: script)
        Preference.remoteAutoFetch.set(true, harness.defaults)

        let originKey = RemoteBranchKey(remote: "origin", branch: "main")
        let upstreamKey = RemoteBranchKey(remote: "upstream", branch: "feat")
        script.checkResult = { remote in
            if remote == "origin" {
                return RemoteDelta(
                    moved: [originKey: RemoteTip(localOID: "a", remoteOID: "b")],
                    currentUpstreamMoved: true, currentUpstreamKey: originKey, checkedAt: clock.now)
            }
            return RemoteDelta(
                moved: [upstreamKey: RemoteTip(localOID: "c", remoteOID: "d")],
                currentUpstreamMoved: false, checkedAt: clock.now)
        }
        script.fetchResult = { remote in
            if remote == "upstream" { throw RemoteCheckError(failure: .unreachable, remote: remote) }
        }

        let snapshot = makeSnapshot(
            root: harness.url,
            remoteURLs: [
                "origin": "https://example.invalid/origin.git",
                "upstream": "https://example.invalid/upstream.git",
            ])
        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: snapshot, defaults: harness.defaults)
        monitor.checkNow(for: harness.url)
        #expect(
            await eventually {
                script.fetchedRemotes == ["origin", "upstream"] && !monitor.state(for: harness.url).isBusy
            })
        let finalDelta = try #require(monitor.state(for: harness.url).last)
        #expect(Array(finalDelta.moved.keys) == [upstreamKey])
        #expect(!finalDelta.currentUpstreamMoved)
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    @Test func synchronousObserverReadsCompletedCheckAndItsDelta() async throws {
        let harness = try ModelHarness()
        let script = ScriptedRemoteRunner()
        let clock = FakeClock()
        let monitor = makeMonitor(clock: clock, runner: script)
        let delta = RemoteDelta(currentUpstreamMoved: true, checkedAt: clock.now)
        script.checkResult = { _ in delta }
        monitor.register(
            model: harness.model, root: harness.url, service: GitService(root: harness.url),
            snapshot: makeSnapshot(root: harness.url), defaults: harness.defaults)
        var phases: [Bool] = []
        let observation = harness.model.observe { change in
            guard change == .providers else { return }
            let current = monitor.state(for: harness.url)
            phases.append(current.isBusy)
            if !current.isBusy {
                guard case .waiting = current.phase else {
                    Issue.record("Expected waiting after check")
                    return
                }
                #expect(current.last == delta)
            }
        }
        defer { harness.model.removeObserver(observation) }
        monitor.checkNow(for: harness.url)
        #expect(await eventually { phases == [true, false] })
    }
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
