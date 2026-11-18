import AppKit
import GitaCore

/// Light status of every repository the user works with (open tabs, recent and session repositories). Open tabs
/// keep their full `AppModel`; this only runs `git status --porcelain=v2 --branch` and `git worktree list
/// --porcelain` per repository, debounced.
///
/// Refreshes at most three repositories at a time, every 60 s while a window or the panel is visible and within ~1 s
/// of a change in each checkout's Git folder (HEAD, index, refs, worktrees; for a linked worktree both its own folder
/// and the shared one). Quiet when nothing is visible: no timer, no watchers; explicit `refresh` calls still run. Git
/// runs with `--no-optional-locks`, so its own reads never trigger a watcher.
@MainActor
final class WorkspaceMonitor {
    static let shared = WorkspaceMonitor()
    private(set) var statuses: [RepositoryStatus] = [] {
        didSet { indexByID = Dictionary(statuses.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    /// `status(for:)` runs on every sidebar and tab rebuild: look up by ID instead of standardizing every root.
    private var indexByID: [String: Int] = [:]

    private var roots: [URL] = []
    private var visible = false
    private var timer: Timer?
    private var watchers: [String: AnyObject] = [:]
    private var debounces: [String: DispatchWorkItem] = [:]
    /// Each repository is idle, waiting in `queue`, or read by its task in `running`; one asked for again while it is
    /// read (`readAgain`) goes back in the queue when that read ends, so a change made mid-read is never missed.
    private var queue: [String] = []
    private var running: [String: Task<Void, Never>] = [:]
    private var readAgain: Set<String> = []
    private var observers: [UUID: @MainActor ([RepositoryStatus]) -> Void] = [:]
    private var notifyScheduled = false
    private let read: @Sendable (URL) async throws -> WorkspaceGitStatus
    private let now: () -> Date
    private let watch: Watch
    private let schedule: Schedule
    /// Starts watching Git folders (`paths`, minus `ignored`) and returns the watcher to keep alive.
    typealias Watch =
        @MainActor (
            _ paths: [String], _ ignored: [String], _ changed: @escaping @MainActor @Sendable () -> Void
        ) -> AnyObject
    /// Runs `item` on the main queue after `delay` seconds.
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ item: DispatchWorkItem) -> Void
    static let concurrency = 3
    static let interval: TimeInterval = 60
    /// Agents run Git constantly; one refresh per repository every 5 s at most is plenty for this summary.
    static let minimumGap: TimeInterval = 5
    /// Objects, logs and hooks change on every commit or fetch without changing anything shown here.
    static let ignoredFolders = ["objects", "logs", "hooks", "lfs", "fsmonitor--daemon"]

    init(
        read: @escaping @Sendable (URL) async throws -> WorkspaceGitStatus = {
            try await WorkspaceStatusReader.read(root: $0)
        },
        now: @escaping () -> Date = Date.init,
        watch: @escaping Watch = { RepositoryWatcher(paths: $0, ignoredPaths: $1, action: $2) },
        schedule: @escaping Schedule = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    ) {
        self.read = read
        self.now = now
        self.watch = watch
        self.schedule = schedule
    }

    /// The repositories to watch, in display order (open tabs first, then recent). Idempotent.
    func setRepositories(_ roots: [URL]) {
        var seen = Set<String>()
        let unique = roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        guard unique.map(\.path) != self.roots.map(\.path) else { return }
        let previous = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        self.roots = unique
        let names = RepositoryStatus.displayNames(unique)
        statuses = unique.map { root in
            var status = previous[root.path] ?? RepositoryStatus(root: root, name: "")
            status.name = names[root.path] ?? root.lastPathComponent
            return status
        }
        let removed = Set(previous.keys).subtracting(seen)
        for id in removed {
            running.removeValue(forKey: id)?.cancel()
            debounces.removeValue(forKey: id)?.cancel()
            readAgain.remove(id)
        }
        queue.removeAll { removed.contains($0) }
        if visible {
            updateWatchers()
            for status in statuses where status.checkedAt == nil { enqueue(status.id) }
        }
        notify()
    }

    func refresh(_ root: URL? = nil) {
        if let root { enqueue(root.standardizedFileURL.path) } else { for root in roots { enqueue(root.path) } }
    }

    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        timer?.invalidate()
        timer = nil
        guard visible else {
            watchers.removeAll()
            for item in debounces.values { item.cancel() }
            debounces.removeAll()
            return
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateWatchers()
        let stale = now().addingTimeInterval(-15)
        for status in statuses where (status.checkedAt ?? .distantPast) < stale { enqueue(status.id) }
    }

    /// Called on every change of `statuses` (not immediately; read `statuses` for the current list).
    @discardableResult func observe(_ handler: @escaping @MainActor ([RepositoryStatus]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func status(for root: URL) -> RepositoryStatus? { indexByID[root.standardizedFileURL.path].map { statuses[$0] } }

    // MARK: Refreshing

    private func enqueue(_ id: String) {
        guard roots.contains(where: { $0.path == id }) else { return }
        if running[id] != nil {
            readAgain.insert(id)
        } else if !queue.contains(id) {
            queue.append(id)
        }
        drain()
    }

    private func drain() {
        while running.count < Self.concurrency, !queue.isEmpty {
            let id = queue.removeFirst()
            let read = read
            running[id] = Task { [weak self] in
                let result: Result<WorkspaceGitStatus, Error>
                if FileManager.default.fileExists(atPath: id) {
                    do { result = .success(try await read(URL(fileURLWithPath: id, isDirectory: true))) } catch {
                        result = .failure(error)
                    }
                } else {
                    result = .failure(CocoaError(.fileNoSuchFile))
                }
                guard let self, !Task.isCancelled else { return }
                self.running[id] = nil
                self.store(result, for: id)
                if self.readAgain.remove(id) != nil { self.queue.append(id) }
                self.drain()
            }
        }
    }

    private func store(_ result: Result<WorkspaceGitStatus, Error>, for id: String) {
        guard let index = statuses.firstIndex(where: { $0.id == id }),
            let status = statuses[index].updated(with: result, at: now()), status != statuses[index]
        else { return }
        statuses[index] = status
        notify()
    }

    /// Coalesced: several repositories finishing in the same moment (launch, the minute timer) rebuild the sidebar
    /// and tabs once, not once each.
    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyScheduled = false
                let current = self.statuses
                for handler in Array(self.observers.values) { handler(current) }
            }
        }
    }

    // MARK: Watching

    private func updateWatchers() {
        let wanted = Set(roots.map(\.path))
        for id in watchers.keys where !wanted.contains(id) { watchers[id] = nil }
        for root in roots where watchers[root.path] == nil {
            guard let location = GitDirectoryLocator.locate(checkout: root) else { continue }
            let id = root.path
            let folders = Array(Set([location.gitDirectory.path, location.commonDirectory.path])).sorted()
            let ignored = folders.flatMap { folder in
                Self.ignoredFolders.map { URL(fileURLWithPath: folder).appendingPathComponent($0).path }
            }
            watchers[id] = watch(folders, ignored) { [weak self] in self?.scheduleRefresh(id) }
        }
    }

    private func scheduleRefresh(_ id: String) {
        debounces[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.debounces[id] = nil
                self?.enqueue(id)
            }
        }
        debounces[id] = item
        let sinceLast = now().timeIntervalSince(status(for: URL(fileURLWithPath: id))?.checkedAt ?? .distantPast)
        schedule(max(1, Self.minimumGap - sinceLast), item)
    }
}
