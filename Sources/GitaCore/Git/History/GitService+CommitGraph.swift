import Foundation

/// Building a commit-graph for a repository whose history walks are slow without one.
///
/// Without `objects/info/commit-graph` Git sorts the whole history before it prints the first topological page
/// (Linux: 6.6 s for every page; 0.1 s with a graph). The graph is Git's own cache of commit parents and generation
/// numbers, the same file `git gc` and `git maintenance` write: building it changes no reference, index, working file
/// or configuration.
extension GitService {
    /// A history walk at least this slow, without a commit-graph, makes building one worthwhile: a graph for such a
    /// history builds in about a second and reads it 5–10 times faster (Kubernetes: 0.72 s a page without one).
    public static let slowWalk = Duration.milliseconds(250)
    /// Writing the graph reads every commit once (Linux: 11 s); a repository many times that size still finishes.
    private static let commitGraphTimeout: GitTimeout = 1_800

    /// A history page starts being read at `start`; `noteWalk` with the same instant ends it.
    func startWalk(_ start: ContinuousClock.Instant) { walks.start(start) }

    /// Records how long the history page read from `start` took (nil: a walk that was not tracked). A walk the actor
    /// let start meanwhile keeps its own start.
    func noteWalk(_ duration: Duration, start: ContinuousClock.Instant? = nil) { walks.end(duration, start: start) }

    /// Whether a history walk has taken `slowWalk` so far and is all that is still being read: no status read runs
    /// beside it. Then the walk is what the window waits for, and a build started now serves the pages after it
    /// (Linux without a graph: status 0.3 s, the walk 6.6 s). While a status runs longer than the walk (a stale index
    /// re-hashed: LLVM, 16 s against 3.5 s), the build would only compete with it for the disk, and waits for the
    /// read to end.
    public func slowWalkAlone(now: ContinuousClock.Instant = .now) -> Bool {
        statusReads == 0 && walks.oldest.map { now - $0 >= Self.slowWalk } ?? false
    }

    /// Whether the last history walk was slow, or the one still running already is, and Git would read a
    /// commit-graph here if there were one.
    public func commitGraphWouldHelp() async -> Bool {
        let running = walks.oldest.map { ContinuousClock.now - $0 } ?? .zero
        guard max(walks.lastDuration, running) >= Self.slowWalk, let state = try? await commitGraphState() else {
            return false
        }
        return state.allowed && !state.present
    }

    /// Writes the commit-graph of every reachable commit (`git commit-graph write --reachable`), from local objects
    /// only, at utility priority (`CommandRequest.upkeep`): it yields to the reads the window waits for. The
    /// walks that follow reduce their tips again (`walkRevisions`).
    public func buildCommitGraph() async throws {
        let local = try await localObjectOptions()
        var request = try await gitRequest(
            local + ["commit-graph", "write", "--reachable", "--no-progress"],
            outputLimit: CommandRequest.defaultOutputLimit, mutation: true)
        Self.commitGraphTimeout.apply(to: &request)
        request.upkeep = true
        let result = try await runner.run(request)
        guard result.exitCode == 0 else { throw Self.failure(result) }
        walkTipCache = nil
        walkTipsUnhelpful = nil
        walks.forgetDuration()
    }

    /// Whether a commit-graph file or chain exists, and whether `core.commitGraph` lets Git read one.
    func commitGraphState() async throws -> (present: Bool, allowed: Bool) {
        async let setting = execute(
            ["config", "--type=bool", "--get", "core.commitGraph"], timeout: 10, outputLimit: 4_096,
            allowFailure: true)
        let present = try await commitGraphFilePresent()
        return (present, GitOutput.withoutTerminalLF(try await setting.text) != "false")
    }

    /// Whether a commit-graph file or chain exists; the folder is asked of Git once, then checked in place.
    func commitGraphFilePresent() async throws -> Bool {
        if objectInfoDirectory == nil {
            let path = try await execute(
                ["rev-parse", "--path-format=absolute", "--git-path", "objects/info"], timeout: 10,
                outputLimit: 64 * 1_024, allowFailure: true)
            if path.exitCode == 0 {
                objectInfoDirectory = URL(fileURLWithPath: GitOutput.withoutTerminalLF(path.text), isDirectory: true)
            }
        }
        return objectInfoDirectory.map(WalkTips.hasCommitGraph(in:)) ?? false
    }
}

/// The history walks being read, each by its own start, and how long the latest took. Two can run at once (a page
/// and a streamed page): one ending leaves the other counted, and walks that overlapped count as one walk, as slow
/// as the slowest of them, so a fast page that ends last does not hide a slow one beside it.
struct HistoryWalks: Sendable {
    /// The starts of the walks still running.
    private var running: [ContinuousClock.Instant] = []
    /// The slowest walk of the latest overlapping walks; zero before any and after a commit-graph build.
    private(set) var lastDuration = Duration.zero
    /// The slowest walk ended so far among walks that overlap one still running.
    private var slowestOfRunningSet: Duration?

    var oldest: ContinuousClock.Instant? { running.min() }

    mutating func start(_ start: ContinuousClock.Instant) { running.append(start) }

    mutating func end(_ duration: Duration, start: ContinuousClock.Instant?) {
        if let start, let index = running.firstIndex(of: start) { running.remove(at: index) }
        let slowest = max(duration, slowestOfRunningSet ?? .zero)
        lastDuration = slowest
        slowestOfRunningSet = running.isEmpty ? nil : slowest
    }

    /// A commit-graph was built: earlier walks say nothing about the next.
    mutating func forgetDuration() {
        lastDuration = .zero
        slowestOfRunningSet = nil
    }
}
