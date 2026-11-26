import Foundation

public actor FlightRecorderService {
    let runner: any CommandRunning
    private let maxSnapshotsPerKey: Int
    private var enabledRepos: Set<String> = []

    public init(maxSnapshotsPerKey: Int = 50, runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
        self.maxSnapshotsPerKey = max(1, maxSnapshotsPerKey)
    }

    private func rootKey(_ root: URL) -> String { root.standardizedFileURL.resolvingSymlinksInPath().path }

    public func setEnabled(_ enabled: Bool, for repositoryRoot: URL) {
        let key = rootKey(repositoryRoot)
        if enabled { enabledRepos.insert(key) } else { enabledRepos.remove(key) }
    }

    public func isEnabled(for repositoryRoot: URL) -> Bool { enabledRepos.contains(rootKey(repositoryRoot)) }

    public func handleHookEvent(_ event: AgentHookEvent, repositoryRoot: URL) async throws -> FlightSnapshot? {
        guard isEnabled(for: repositoryRoot) else { return nil }
        let trigger: FlightSnapshotTrigger
        switch (event.tool, event.event) {
        case (.claudeCode, "UserPromptSubmit"): trigger = .userPromptSubmit
        case (.claudeCode, "Stop"): trigger = .agentStop
        case (.codex, "notify") where event.kind == "agent-turn-complete": trigger = .codexTurnComplete
        default: return nil
        }
        guard let worktree = try await hookWorktree(event.cwd, in: repositoryRoot) else { return nil }
        let key = event.sessionID ?? rootKey(worktree)
        return try await captureSnapshot(
            in: worktree, key: key, trigger: trigger,
            tool: event.tool, sessionID: event.sessionID)
    }

    private func hookWorktree(_ cwd: String?, in repository: URL) async throws -> URL? {
        guard let cwd else { return repository }
        let git = AgentControlGit(root: repository, runner: runner)
        let listing = try await git.run(["worktree", "list", "--porcelain", "-z"])
        let directory = rootKey(URL(fileURLWithPath: cwd))
        let roots = GitParsers.worktrees(listing.stdout).filter { !$0.isBare && !$0.isPrunable }
            .map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }
        return roots.filter { AgentCheckoutResolver.isInside(directory, root: $0.path) }
            .max { $0.path.count < $1.path.count }
    }

    private func refName(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var safe = String(key.unicodeScalars.prefix(160).map { allowed.contains($0) ? Character(String($0)) : "-" })
        while safe.contains("..") { safe = safe.replacingOccurrences(of: "..", with: ".") }
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if safe.isEmpty { safe = "default" }
        if safe != key || safe.hasSuffix(".lock") { safe += "-" + Data(key.utf8).sha256Hex.prefix(16) }
        return "refs/gita/snapshots/" + safe
    }

    public func captureSnapshot(
        in repositoryRoot: URL, key: String = "default", trigger: FlightSnapshotTrigger = .manual,
        tool: AgentTool? = nil, sessionID: String? = nil, label: String? = nil
    ) async throws -> FlightSnapshot {
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let ref = refName(key)
        let tree = try await git.worktreeTree()
        let head = try await git.resolve("HEAD")
        // update-ref compares the old value atomically across actors, windows and app instances.
        for _ in 0..<8 {
            let previous = try await git.resolve(ref)
            let parent = previous ?? head
            let sequence = try await nextSequence(git, tip: previous, ref: ref)
            let count = try await changedFileCount(git, parent: parent, tree: tree)
            let metadata = FlightSnapshotMetadata(
                trigger: trigger, tool: tool, sessionID: sessionID,
                label: label ?? "Turn \(sequence)", sequence: sequence, count: count)
            let identity = ["-c", "user.name=Gita Flight Recorder", "-c", "user.email=gita@localhost"]
            let args = identity + ["commit-tree", tree] + (parent.map { ["-p", $0] } ?? [])
            let commit = try await git.oid(args + ["-m", try metadata.message(ref: ref)])
            let old = previous ?? String(repeating: "0", count: commit.count)
            let update = try await git.run(["update-ref", "--no-deref", ref, commit, old], accepting: [0, 128])
            if update.exitCode == 0 {
                guard
                    let snapshot = try await FlightSnapshotMetadata.list(git: git, tip: commit, ref: ref, limit: 1)
                        .first
                else { throw GitError.invalidReference }
                return snapshot
            }
            if try await git.resolve(ref) == previous { throw GitService.failure(update) }
        }
        throw GitError.staleReference
    }

    private func nextSequence(_ git: AgentControlGit, tip: String?, ref: String) async throws -> Int {
        guard let tip else { return 1 }
        guard let last = try await FlightSnapshotMetadata.list(git: git, tip: tip, ref: ref, limit: 1).first,
            last.sequence < Int.max
        else { throw GitError.invalidReference }
        return last.sequence + 1
    }

    private func changedFileCount(_ git: AgentControlGit, parent: String?, tree: String) async throws -> Int {
        if let parent { return try await git.files(from: parent, to: tree).count }
        let files = try await git.run(["ls-tree", "-r", "--name-only", "-z", tree])
        return files.stdout.split(separator: 0).count
    }

    public func listSnapshots(
        in repositoryRoot: URL, key: String = "default", limit: Int = 50
    ) async throws -> [FlightSnapshot] {
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let ref = refName(key)
        guard limit > 0, let tip = try await git.resolve(ref) else { return [] }
        return try await FlightSnapshotMetadata.list(
            git: git, tip: tip, ref: ref, limit: min(limit, maxSnapshotsPerKey))
    }

    public func clearSnapshots(in repositoryRoot: URL, key: String = "default") async throws {
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let ref = refName(key)
        if let previous = try await git.resolve(ref) {
            try await git.run(["update-ref", "--no-deref", "-d", ref, previous])
        }
    }
}
