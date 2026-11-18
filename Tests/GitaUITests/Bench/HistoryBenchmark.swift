import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Opens a large real repository (read-only) and times every stage from `git` to drawn rows. Skipped unless
/// `GITA_BENCH_REPO` names a repository; measure a release build:
///
///     GITA_BENCH_REPO=~/src/linux swift test -c release -Xswiftc -enable-testing --filter HistoryBenchmark
///
/// The Linux kernel (1.5M commits, 950 references, 97k files) is the reference case. The window test keeps Settings ›
/// Git › Speed up slow repositories on, as a new user has it: without a commit-graph it also measures the background
/// build, which writes `objects/info/commit-graph` like `git gc` does, and a slow status refreshes the index's stat
/// data (`git update-index --refresh`). Both are Git's own caches: no reference, staged content or working file
/// changes.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GITA_BENCH_REPO"] != nil))
struct HistoryBenchmark {
    nonisolated static let repository = ProcessInfo.processInfo.environment["GITA_BENCH_REPO"].map {
        URL(fileURLWithPath: $0)
    }

    static func report(_ label: String, _ duration: Duration) {
        let milliseconds = Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3
        let name = label.padding(toLength: 52, withPad: " ", startingAt: 0)
        print("BENCH " + name + String(format: "%10.2f ms", milliseconds))
    }

    static func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let value = try await body()
        report(label, ContinuousClock.now - start)
        return value
    }

    static func percentile(_ samples: [Duration], _ fraction: Double) -> Duration {
        let sorted = samples.sorted()
        return sorted.isEmpty ? .zero : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    /// One page of the history walk, as the app reads it, at a few depths.
    @Test func historyPages() async throws {
        let service = GitService(root: try #require(Self.repository))
        for skip in [0, 10_000, 100_000] {
            let page = try await Self.time("history page at \(skip)") {
                try await service.history(limit: HistoryPage.request, skip: skip)
            }
            #expect(!page.isEmpty)
        }
        let snapshot = try await Self.time("snapshot (new service)") {
            try await GitService(root: try #require(Self.repository)).snapshot(limit: HistoryPage.size)
        }
        print("BENCH   \(snapshot.commits.count) commits, \(snapshot.references.count) references")
        let commits = try await service.history(limit: 10_000, skip: 0)
        let rows = await Self.time("graph layout of 10 000 rows") { GraphLayout.build(commits: commits) }
        let edges = rows.reduce(0) { $0 + $1.incoming.count + $1.outgoing.count }
        let megabytes = edges * MemoryLayout<GraphEdge>.stride / 1_048_576
        print("BENCH   \(HistoryListState.lastLane(of: rows) + 1) lanes, \(edges) edges, \(megabytes) MB of edges")
    }

    /// Drawing the graph cell of 60 rows near the top and 60 rows deep in the history (Linux: 200 lines a row).
    @Test func graphDrawing() async throws {
        UITestSupport.bootstrap()
        let commits = try await GitService(root: try #require(Self.repository)).history(limit: 10_001, skip: 0)
        let rows = GraphLayout.build(commits: commits)
        let cell = GraphCell(frame: NSRect(x: 0, y: 0, width: 1_800, height: 24))
        let bitmap = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        for (label, range) in [("top", 1..<61), ("deep", (rows.count - 61)..<(rows.count - 1))] {
            let widest = rows[range].map { $0.incoming.count + $0.outgoing.count }.max() ?? 0
            let start = ContinuousClock.now
            for _ in 0..<10 {
                for row in range {
                    cell.previous = rows[row - 1]
                    cell.row = rows[row]
                    cell.next = rows[row + 1]
                    cell.cacheDisplay(in: cell.bounds, to: bitmap)
                }
            }
            Self.report("draw 60 \(label) graph rows (\(widest) lines/row)", (ContinuousClock.now - start) / 10)
        }
    }

    /// The window: open, render, scroll, page through 10 000 commits and refresh.
    @Test func window() async throws {
        let root = try #require(Self.repository)
        let bench = try await WindowBench(root: root)
        defer { bench.close() }
        let model = bench.model
        let opened = ContinuousClock.now
        model.refresh()
        try await bench.wait { bench.table.numberOfRows > 0 }
        Self.report("open → first history rows", ContinuousClock.now - opened)
        try await bench.wait { !model.isLoading }
        Self.report("open → fully read", ContinuousClock.now - opened)
        try await bench.wait { model.gitCaches.graphTask == nil }
        if model.events.contains(where: { $0.title == String(localized: "Built commit-graph") }) {
            Self.report("open → commit-graph built", ContinuousClock.now - opened)
        }
        Self.report("first render of the visible rows", bench.frame())
        try await Self.time("refresh, nothing changed") {
            model.refresh()
            try await bench.wait { !model.isLoading }
        }
        let steps = (1...120).map { step in bench.frame(scrolledTo: CGFloat(step) * 12) }
        Self.report("12 pt scroll frame, median", Self.percentile(steps, 0.5))
        Self.report("12 pt scroll frame, p95", Self.percentile(steps, 0.95))
        let stalls = StallMeter()
        stalls.start()
        var pages: [Duration] = []
        while model.snapshot?.hasMoreHistory == true, model.snapshot?.commits.count ?? 0 < 20_000 {
            let start = ContinuousClock.now
            model.loadMore()
            try await bench.wait { !model.isLoading }
            pages.append(ContinuousClock.now - start)
        }
        stalls.stop()
        Self.report("history page, median of \(pages.count)", Self.percentile(pages, 0.5))
        Self.report("history page, max", Self.percentile(pages, 1))
        Self.report("paging to \(model.snapshot?.commits.count ?? 0) commits, total", pages.reduce(.zero, +))
        Self.report("longest main-thread stall while paging", stalls.longest)
        let bottom = CGFloat(bench.table.numberOfRows - 200) * bench.table.rowHeight
        let deep = (0..<40).map { step in bench.frame(scrolledTo: bottom + CGFloat(step) * 12) }
        Self.report("12 pt scroll frame deep in history, p95", Self.percentile(deep, 0.95))
    }
}

/// A repository window over the benchmark repository, its model reading it the way a newly opened tab does.
@MainActor
final class WindowBench {
    let model: AppModel
    let controller: RepositoryViewController
    let window: NSWindow
    private let suiteName = "GitaBench.\(UUID().uuidString)"
    var table: NSTableView { controller.historyTable.table }

    init(root: URL) async throws {
        UITestSupport.bootstrap()
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RepositoryWindowFixture.Timeout(what: "a defaults suite")
        }
        model = AppModel(defaults: defaults)
        // As `AppModel.open` leaves it: a service and no snapshot, so the first read is the repository's first.
        model.service = GitService(root: root)
        model.root = root
        controller = RepositoryViewController(model: model, commands: RecordingCommands())
        window = UITestSupport.host(controller, size: NSSize(width: 1_600, height: 1_000))
    }

    func close() {
        controller.detach()
        model.stop()
        window.close()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(600)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RepositoryWindowFixture.Timeout(what: "the benchmark") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Scrolls (when asked), lays out and draws the visible rows; how long that took.
    func frame(scrolledTo y: CGFloat? = nil) -> Duration {
        let start = ContinuousClock.now
        if let y {
            let clip = controller.historyTable.scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: y))
            controller.historyTable.scroll.reflectScrolledClipView(clip)
        }
        window.layoutIfNeeded()
        let visible = table.visibleRect
        if let bitmap = table.bitmapImageRepForCachingDisplay(in: visible) {
            table.cacheDisplay(in: visible, to: bitmap)
        }
        return ContinuousClock.now - start
    }
}

/// The longest gap between 1 ms main-thread timer ticks: how long the main thread was busy at once.
@MainActor
final class StallMeter {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private(set) var longest = Duration.zero

    func start() {
        last = ContinuousClock.now
        timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ContinuousClock.now
                self.longest = max(self.longest, now - self.last)
                self.last = now
            }
        }
    }

    func stop() { timer?.invalidate() }
}
