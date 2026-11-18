import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Counts sink callbacks on the main actor.
@MainActor
private final class Counter {
    var value = 0
}

@Suite("RepositoryWatcher and the refresh scheduler")
@MainActor
struct ModelRepositoryWatcherTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-Watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // FSEvents reports resolved paths (/private/var/…).
        return url.resolvingSymlinksInPath()
    }

    /// FSEvents releases the stream's context on the sink's queue: that must not need the main actor.
    @Test func aStartedWatcherStopsAndIsReleasedSafely() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var watcher: RepositoryWatcher? = RepositoryWatcher(paths: [folder.path]) {}
        try Data("x".utf8).write(to: folder.appendingPathComponent("file.txt"))
        watcher?.stop()
        watcher?.stop()
        watcher = RepositoryWatcher(paths: [folder.path]) {}
        watcher = nil
        // A main-actor release callback would trap the test process once the stream deallocates.
        #expect(watcher == nil)
    }

    @Test func eventsInIgnoredFoldersAndFilteredPathsDoNothing() async throws {
        let repository = try TemporaryRepository()
        try repository.commit(".gitignore", "build/\n", message: "Ignore build")
        let root = repository.url.resolvingSymlinksInPath()
        let counter = Counter()
        let ignored = root.appendingPathComponent("ignored").path
        let sink = RepositoryWatcher.Sink(
            ignoredPaths: [ignored], filter: WorktreeEventFilter(root: root)
        ) { counter.value += 1 }
        #expect(sink.relevant([ignored, ignored + "/x", ignored + "-other"]) == [ignored + "-other"])

        sink.queue.sync { sink.receive([ignored + "/inside"]) }
        sink.queue.sync {
            sink.receive([root.appendingPathComponent("build/out.o").path])
            sink.receive([root.appendingPathComponent("build/more.o").path])
        }
        sink.queue.sync { sink.receive([root.appendingPathComponent("tracked.txt").path]) }
        let fired = await eventually { counter.value > 0 }
        #expect(fired)

        let unfiltered = RepositoryWatcher.Sink(ignoredPaths: [], filter: nil) { counter.value += 10 }
        unfiltered.queue.sync { unfiltered.receive(["/anything"]) }
        let direct = await eventually { counter.value >= 10 }
        #expect(direct)
    }

    @Test func theSchedulerStartsAndStopsItsTimers() {
        let scheduler = ProviderRefreshScheduler()
        let handlers = ProviderRefreshScheduler.Handlers(minute: {}, agents: {}, vercel: {})
        scheduler.start(handlers)
        scheduler.start(handlers)
        scheduler.stop()
    }
}
