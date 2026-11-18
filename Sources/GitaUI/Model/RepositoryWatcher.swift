import CoreServices
import Foundation
import GitaCore

/// FSEvents supplies one coalesced event stream for the selected repository; no recurring Git poll.
@MainActor
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let sink: Sink
    private static let latency: CFTimeInterval = 0.5

    /// Receives FSEvents batches on its own utility queue (path bridging and filtering never touch the main thread)
    /// and calls `action` on the main actor only for a batch that can matter. The stream retains the sink, so a
    /// callback in flight outlives the watcher safely.
    final class Sink: @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.clevermechanisms.Gita.watcher", qos: .utility)
        let ignoredPaths: [String]
        let filter: WorktreeEventFilter?
        let action: @MainActor @Sendable () -> Void
        private var classifying = false, deferred: [String] = [] // queue-confined
        init(ignoredPaths: [String], filter: WorktreeEventFilter?, action: @escaping @MainActor @Sendable () -> Void) {
            self.ignoredPaths = ignoredPaths
            self.filter = filter
            self.action = action
        }
        /// Paths outside the ignored folders (the object database and the like).
        func relevant(_ paths: [String]) -> [String] {
            paths.filter { path in !ignoredPaths.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
        /// Called on `queue`.
        func receive(_ paths: [String]) {
            let relevant = relevant(paths)
            guard !relevant.isEmpty else { return }
            guard let filter else {
                fire()
                return
            }
            // One classification at a time; events arriving meanwhile are judged together afterwards.
            if classifying {
                deferred.append(contentsOf: relevant)
                return
            }
            classify(relevant, filter)
        }
        private func classify(_ paths: [String], _ filter: WorktreeEventFilter) {
            classifying = true
            Task.detached(priority: .utility) { [self] in
                let matters = await filter.isRelevant(paths)
                self.queue.async {
                    if matters { self.fire() }
                    let next = self.deferred
                    self.deferred = []
                    if next.isEmpty { self.classifying = false } else { self.classify(next, filter) }
                }
            }
        }
        private func fire() {
            let action = action
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
    }

    init(
        paths: [String], ignoredPaths: [String] = [], filter: WorktreeEventFilter? = nil,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        sink = Sink(ignoredPaths: ignoredPaths, filter: filter, action: action)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: retainWatcherSink,
            release: releaseWatcherSink, copyDescription: nil)
        stream = FSEventStreamCreate(
            nil, deliverWatcherEvents, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, sink.queue)
            FSEventStreamStart(stream)
        }
    }

    /// Ends the event stream now (releasing the watcher does too); no batch is delivered after it.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }
}

// The stream's callbacks run on the sink's queue (events, the final release) or wherever FSEvents retains the
// context: plain functions, never isolated to the main actor.

private func retainWatcherSink(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    info.map { _ = Unmanaged<RepositoryWatcher.Sink>.fromOpaque($0).retain() }
    return info
}

private func releaseWatcherSink(_ info: UnsafeRawPointer?) {
    info.map { Unmanaged<RepositoryWatcher.Sink>.fromOpaque($0).release() }
}

private func deliverWatcherEvents(
    _: ConstFSEventStreamRef, info: UnsafeMutableRawPointer?, count: Int, rawPaths: UnsafeMutableRawPointer,
    _: UnsafePointer<FSEventStreamEventFlags>, _: UnsafePointer<FSEventStreamEventId>
) {
    guard let info, count > 0 else { return }
    let sink = Unmanaged<RepositoryWatcher.Sink>.fromOpaque(info).takeUnretainedValue()
    sink.receive(unsafeBitCast(rawPaths, to: CFArray.self) as? [String] ?? [])
}
