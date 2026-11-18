import Foundation

/// Every Git read and write for one working copy. Reads run concurrently; writes go through one mutation gate in
/// call order, so a preflight read can never race the mutation queued before it. Feature areas live in
/// `GitService+<Feature>.swift` extensions.
public actor GitService {
    public let root: URL
    let runner: any CommandRunning
    private var resolvedRoot: URL?
    private var rootResolution: Task<URL, Error>?
    private var mutationBusy = false
    private var mutationWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// Whether the installed Git accepts `--no-lazy-fetch`; probed once, because older macOS system Git rejects it.
    var noLazyFetch = GitFeatureProbe.unknown
    var history = HistoryCacheState()
    /// The independent tips of the last history walk, while the references stay the same (`walkRevisions`).
    var walkTipCache: WalkTips.Cache?
    /// The walk further history pages continue (`streamedHistory`).
    var historyStream: HistoryStream?
    /// A scope whose tips did not reduce enough to pay, and until when it walks Git's own arguments.
    var walkTipsUnhelpful: (scope: HistoryScope, until: ContinuousClock.Instant)?
    /// `objects/info` of this repository, where a commit-graph lives.
    var objectInfoDirectory: URL?
    /// The history pages being read, and how long the latest took (`commitGraphWouldHelp`, `slowWalkAlone`).
    var walks = HistoryWalks()
    /// How long the latest status read took, the folder holding this worktree's index, and when the index was last
    /// refreshed (`refreshIndexIfStale`).
    var lastStatusDuration = Duration.zero
    /// Status reads running now (`slowWalkAlone`).
    var statusReads = 0
    var indexDirectory: URL?
    var lastIndexRefresh: ContinuousClock.Instant?
    /// Whether refreshing the index pays in this repository (`IndexRefreshTrial`).
    var indexRefreshTrial = IndexRefreshTrial.allowed

    public init(root: URL, runner: any CommandRunning = CommandRunner()) {
        self.root = root.standardizedFileURL
        self.runner = runner
    }

    /// Resolve once before every entry point, including a write without a prior snapshot.
    /// Porcelain paths are relative to the repository root, not to the selected subfolder.
    func repositoryRoot() async throws -> URL {
        if let resolvedRoot { return resolvedRoot }
        if let rootResolution { return try await rootResolution.value }
        let runner = runner
        let selected = root
        let task = Task {
            let result = try await runner.run(
                CommandRequest.git(
                    ["--no-optional-locks", "rev-parse", "--show-toplevel"], directory: selected, timeout: 10,
                    outputLimit: 64 * 1_024))
            let path = GitOutput.withoutTerminalLF(result.text)
            guard result.exitCode == 0, path.hasPrefix("/") else { throw GitError.notRepository }
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        }
        rootResolution = task
        defer { rootResolution = nil }
        let result = try await task.value
        resolvedRoot = result
        return result
    }

    // MARK: Mutation gate

    /// Runs `operation` alone among this service's mutations, in call order. Actor reentrancy must not let
    /// preflight reads race a preceding mutation.
    func mutate<T: Sendable>(_ operation: @escaping @Sendable (isolated GitService) async throws -> T) async throws -> T
    {
        try await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()
        return try await operation(self)
    }

    func mutate(_ arguments: [String], timeout: GitTimeout = .standard) async throws {
        try await mutate { service in _ = try await service.execute(arguments, timeout: timeout, mutation: true) }
    }

    private func acquireMutation() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !mutationBusy {
                    mutationBusy = true
                    continuation.resume()
                } else {
                    mutationWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelMutationWaiter(id) }
        }
    }

    private func cancelMutationWaiter(_ id: UUID) {
        guard let index = mutationWaiters.firstIndex(where: { $0.id == id }) else { return }
        mutationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationBusy = false
        } else {
            mutationWaiters.removeFirst().continuation.resume()
        }
    }
}
