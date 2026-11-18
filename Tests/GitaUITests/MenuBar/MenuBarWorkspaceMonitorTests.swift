import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarWorkspaceMonitorTests {
    typealias MF = MenuBarFixtures

    /// A stand-in file watcher: what it watches, and its change callback for the test to fire.
    @MainActor final class Watch {
        let paths: [String]
        let ignored: [String]
        let changed: @MainActor @Sendable () -> Void
        init(_ paths: [String], _ ignored: [String], _ changed: @escaping @MainActor @Sendable () -> Void) {
            self.paths = paths
            self.ignored = ignored
            self.changed = changed
        }
    }

    /// Everything the monitor reaches outside itself, recorded.
    @MainActor final class Harness {
        var watches: [Watch] = []
        var scheduled: [(delay: TimeInterval, item: DispatchWorkItem)] = []
        var clock = MenuBarFixtures.now
        let reads = ReadLog()

        func monitor(
            read: (@Sendable (URL) async throws -> WorkspaceGitStatus)? = nil
        ) -> WorkspaceMonitor {
            let log = reads
            return WorkspaceMonitor(
                read: read ?? { url in
                    await log.append(url.lastPathComponent)
                    return MenuBarFixtures.gitStatus(branch: "main", changed: 1)
                },
                now: { [self] in clock },
                watch: { [self] paths, ignored, changed in
                    let watch = Watch(paths, ignored, changed)
                    watches.append(watch)
                    return watch
                },
                schedule: { [self] delay, item in scheduled.append((delay, item)) })
        }
    }

    actor ReadLog {
        private(set) var names: [String] = []
        func append(_ name: String) { names.append(name) }
    }

    /// Resumes once, the first time the monitor's statuses satisfy `condition`.
    private func statuses(
        of monitor: WorkspaceMonitor, where condition: @escaping ([RepositoryStatus]) -> Bool
    ) async -> [RepositoryStatus] {
        if condition(monitor.statuses) { return monitor.statuses }
        let box = Once()
        return await withCheckedContinuation { continuation in
            box.token = monitor.observe { statuses in
                guard condition(statuses), let token = box.token else { return }
                box.token = nil
                monitor.removeObserver(token)
                continuation.resume(returning: statuses)
            }
        }
    }

    @MainActor final class Once {
        var token: UUID?
    }

    private func folders(_ names: String...) throws -> (URL, [URL]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-\(UUID().uuidString)")
        let urls = names.map { base.appendingPathComponent($0, isDirectory: true) }
        for url in urls { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return (base, urls)
    }

    @Test func readsARealRepositoryOnRefresh() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a", message: "first")
        try repository.write("b.txt", "untracked")
        let monitor = WorkspaceMonitor()
        monitor.setRepositories([repository.url])
        #expect(monitor.statuses.map(\.name) == [repository.url.lastPathComponent])
        monitor.refresh()
        let read = await statuses(of: monitor) { $0.first?.checkedAt != nil }
        #expect(read.first?.branch == "main")
        #expect(read.first?.changedFiles == 1)
        #expect(read.first?.error == nil)
        #expect(monitor.status(for: repository.url)?.branch == "main")
    }

    @Test func namesClashesAndReportsMissingAndUnreadableFolders() async throws {
        let (base, urls) = try folders("one/app", "two/app")
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("gone", isDirectory: true)
        let harness = Harness()
        let monitor = harness.monitor { url in
            if url.path.contains("/two/") { throw WorkspaceStatusError.notRepository }
            return MenuBarFixtures.gitStatus(branch: "dev")
        }
        monitor.setRepositories(urls + [missing, urls[0]])
        #expect(monitor.statuses.map(\.name) == ["one/app", "two/app", "gone"])
        monitor.refresh()
        let read = await statuses(of: monitor) { $0.allSatisfy { $0.checkedAt != nil } }
        #expect(read.map(\.error) == [nil, "Not a repository", "Not found"])
        #expect(read[0].branch == "dev")
    }

    @Test func settingTheSameRepositoriesChangesNothingAndRemovingDropsTheirStatus() async throws {
        let (base, urls) = try folders("a", "b")
        defer { try? FileManager.default.removeItem(at: base) }
        let harness = Harness()
        let monitor = harness.monitor()
        var notified = 0
        monitor.observe { _ in notified += 1 }
        monitor.setRepositories(urls)
        monitor.setRepositories(urls)
        await MF.drainMainQueue()
        #expect(notified == 1)
        monitor.refresh(urls[1])
        _ = await statuses(of: monitor) { $0.last?.checkedAt != nil }
        #expect(await harness.reads.names == ["b"])
        monitor.setRepositories([urls[1]])
        #expect(monitor.statuses.map(\.name) == ["b"])
        #expect(monitor.statuses[0].checkedAt != nil)
        #expect(monitor.status(for: urls[0]) == nil)
        monitor.refresh(urls[0])
        await MF.drainMainQueue()
        #expect(await harness.reads.names == ["b"])
    }

    @Test func visibleMonitorWatchesGitFoldersAndRefreshesStaleOnes() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a", message: "first")
        let plain = try folders("plain")
        defer { try? FileManager.default.removeItem(at: plain.0) }
        let harness = Harness()
        let monitor = harness.monitor()
        monitor.setRepositories([repository.url, plain.1[0]])
        monitor.setVisible(true)
        monitor.setVisible(true)
        // The plain folder has no Git data to watch; the repository's `.git` is watched without its object store.
        #expect(harness.watches.count == 1)
        let watch = try #require(harness.watches.first)
        #expect(watch.paths == [repository.url.appendingPathComponent(".git").path])
        #expect(watch.ignored.contains(repository.url.appendingPathComponent(".git/objects").path))
        _ = await statuses(of: monitor) { $0.allSatisfy { $0.checkedAt != nil } }
        #expect(Set(await harness.reads.names) == [repository.url.lastPathComponent, "plain"])

        // A change is debounced, and held back while the last read is recent.
        watch.changed()
        watch.changed()
        #expect(harness.scheduled.count == 2)
        #expect(harness.scheduled[0].item.isCancelled)
        #expect(harness.scheduled[1].delay == WorkspaceMonitor.minimumGap)
        harness.clock = MF.now.addingTimeInterval(60)
        watch.changed()
        #expect(harness.scheduled[2].delay == 1)
        harness.scheduled[2].item.perform()
        let later = MF.now.addingTimeInterval(60)
        _ = await statuses(of: monitor) { $0.first?.checkedAt == later }
        #expect(await harness.reads.names.count == 3)

        // Hidden: no watchers and no pending refreshes.
        watch.changed()
        monitor.setVisible(false)
        #expect(harness.scheduled[3].item.isCancelled)
        // Shown again, the folders are watched afresh.
        monitor.setVisible(true)
        #expect(harness.watches.count == 2)
        monitor.setVisible(false)
    }

    @Test func repositoriesAddedWhileVisibleAreWatchedAndReadAtOnce() async throws {
        let first = try TemporaryRepository()
        let second = try TemporaryRepository()
        let harness = Harness()
        let monitor = harness.monitor()
        monitor.setVisible(true)
        monitor.setRepositories([first.url])
        _ = await statuses(of: monitor) { $0.allSatisfy { $0.checkedAt != nil } }
        monitor.setRepositories([first.url, second.url])
        #expect(harness.watches.count == 2)
        _ = await statuses(of: monitor) { $0.count == 2 && $0.allSatisfy { $0.checkedAt != nil } }
        #expect(await harness.reads.names.count == 2)
        monitor.setRepositories([second.url])
        monitor.setVisible(false)
    }

    /// Holds reads until released.
    actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    /// A change while a repository is being read (its Git folder moved under the read) reads it once more after.
    @Test func aRefreshAskedForMidReadReadsAgainAfterIt() async throws {
        let (base, urls) = try folders("a")
        defer { try? FileManager.default.removeItem(at: base) }
        let harness = Harness()
        let gate = Gate()
        let log = harness.reads
        let monitor = harness.monitor { url in
            await log.append(url.lastPathComponent)
            await gate.wait()
            return MF.gitStatus(branch: "main", changed: 1)
        }
        monitor.setRepositories(urls)
        monitor.refresh(urls[0])
        monitor.refresh(urls[0])
        monitor.refresh(urls[0])
        await gate.open()
        _ = await statuses(of: monitor) { $0.first?.checkedAt != nil }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while await log.names.count < 2, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.names == ["a", "a"], "one more read for any number of requests made during the first")
    }
}
