import Foundation

/// The periodic repository snapshot: status, references, worktrees, stashes, operation state and a history page.
extension GitService {
    private static let snapshotLimit = 10_000

    /// `scope`: the sidebar's branch filters; references that no longer exist are dropped from it (the snapshot's
    /// `historyScope` is what was walked, for paging).
    ///
    /// The history walk depends only on the references, HEAD and ancestry metadata, so it starts as soon as those are
    /// read and runs while `git status` scans the working tree. In a large checkout status is the slower of the two:
    /// `early` then gets the history first, as a snapshot without working-tree changes, worktrees or stashes
    /// (`RepositorySnapshot.isPreview`), so the list can show before status ends. It is not called when status
    /// finishes first.
    public func snapshot(
        limit: Int = 500, scope: HistoryScope = .all,
        early: (@Sendable (RepositorySnapshot) async -> Void)? = nil
    ) async throws -> RepositorySnapshot {
        let maximum = min(max(limit, 1), Self.snapshotLimit)
        let repoRoot = try await repositoryRoot()
        return try await withThrowingTaskGroup(of: SnapshotPart.self) { group in
            group.addTask { .status(try await self.timedStatus()) }
            async let worktreesRead = execute(["worktree", "list", "--porcelain", "-z"])
            async let stashesRead = execute(["stash", "list", "-n", "250", "--format=%gd%x00%s", "-z"])
            async let originRead = execute(["remote", "get-url", "origin"], allowFailure: true)
            let walk = try await historyWalk(limit: maximum, scope: scope, root: repoRoot)
            group.addTask { .history(try await self.cachedHistory(key: walk.key, commonDirectory: walk.common)) }
            var status: CommandResult?
            var commits: [GitCommit] = []
            while let part = try await group.next() {
                switch part {
                case .status(let result): status = result
                case .history(let walked):
                    commits = walked
                    if status == nil, let early { await early(walk.preview(walked)) }
                }
            }
            // Both parts ran (a failure would have thrown).
            guard let status else { throw CancellationError() }
            let (worktrees, stashes, origin) = try await (worktreesRead, stashesRead, originRead)
            return try await finish(
                walk, commits: commits, status: GitParsers.status(status.stdout), worktrees: worktrees,
                stashes: stashes, origin: origin)
        }
    }

    private enum SnapshotPart: Sendable {
        case status(CommandResult)
        case history([GitCommit])
    }

    /// The references, HEAD and Git folders a snapshot's history walk depends on, and what it walks.
    private func historyWalk(limit maximum: Int, scope: HistoryScope, root: URL) async throws -> SnapshotWalk {
        // Every ref is part of the fingerprint: --all history also sees stash and replace refs.
        async let referencesRead = execute(GitArguments.referenceList)
        async let headRead = headCommit()
        async let directoriesRead = gitDirectories()
        let (referenceList, walkedHead, directories) = try await (referencesRead, headRead, directoriesRead)
        let gitDirectory = URL(fileURLWithPath: directories.gitDirectory, isDirectory: true)
        indexDirectory = gitDirectory
        let common = URL(fileURLWithPath: directories.commonDirectory, isDirectory: true).resolvingSymlinksInPath()
        let references = GitParsers.references(referenceList.stdout)
        let walked = scope.isAll ? scope : scope.restricted(to: Set(references.map(\.fullName)))
        let key = HistoryKey(
            head: walkedHead, references: referenceList.stdout, limit: maximum + 1,
            ancestryMetadata: AncestryMetadata.identity(commonDirectory: common), scope: walked)
        return SnapshotWalk(
            root: root, gitDirectory: gitDirectory, common: common, references: references, key: key,
            limit: maximum)
    }

    private func finish(
        _ walk: SnapshotWalk, commits: [GitCommit], status: GitParsers.Status, worktrees: CommandResult,
        stashes: CommandResult, origin: CommandResult
    ) async throws -> RepositorySnapshot {
        let preferred = origin.exitCode == 0 ? GitOutput.withoutTerminalLF(origin.text) : ""
        var snapshot = walk.preview(commits)
        snapshot.isPreview = false
        snapshot.branch = status.branch
        snapshot.head = status.head
        snapshot.ahead = status.ahead
        snapshot.behind = status.behind
        snapshot.changes = status.changes
        snapshot.worktrees = GitParsers.worktrees(worktrees.stdout)
        snapshot.stashes = GitParsers.stashes(stashes.stdout)
        let remote = try await snapshotRemoteURL(preferred: preferred, branch: status.branch)
        snapshot.remoteURL = remote.map(RemoteURLPolicy.displayURL)
        let resolver = GitHubRemoteResolver(runner: runner)
        snapshot.github = await resolver.resolve(remote)
        let urls = await remoteURLs()
        snapshot.remoteURLs = urls
        snapshot.githubRemotes = await githubRemoteNames(
            in: urls, primary: remote, primaryResolved: snapshot.github != nil, resolver: resolver)
        // HEAD moved between the walk and the status read: the page is not validated for this HEAD.
        snapshot.historyIdentity = status.head == walk.key.head ? history.identity(for: walk.key) : nil
        snapshot.operation = try OperationStateReader.read(directory: walk.gitDirectory, head: status.head)
        return snapshot
    }

    /// The working-tree status, timed (`indexRefreshWouldHelp`).
    private func timedStatus() async throws -> CommandResult {
        statusReads += 1
        defer { statusReads -= 1 }
        let start = ContinuousClock.now
        let result = try await execute(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        noteStatus(ContinuousClock.now - start, startedAt: start)
        return result
    }

    /// Do not walk a large DAG again unless its tips, shallow boundaries, or the requested page changed.
    private func cachedHistory(key: HistoryKey, commonDirectory: URL) async throws -> [GitCommit] {
        try Task.checkCancellation()
        if let entry = history.entry, entry.key == key { return entry.commits }
        if let load = history.load, load.key == key {
            let commits = try await load.task.value.commits
            try Task.checkCancellation()
            return commits
        }
        let id = UUID()
        let task = Task { try await validatedHistory(key: key, commonDirectory: commonDirectory) }
        history.load = HistoryCacheState.Load(key: key, id: id, task: task)
        do {
            let (commits, valid) = try await task.value
            // An older request must never overwrite a newer snapshot's cache.
            if history.load?.id == id {
                if valid {
                    history.entry = HistoryCacheState.Entry(key: key, commits: commits)
                    // The references moved: a running walk describes the history before.
                    if historyStream?.snapshot != key { closeHistoryStream() }
                }
                history.load = nil
            }
            try Task.checkCancellation()
            return commits
        } catch {
            if history.load?.id == id { history.load = nil }
            throw error
        }
    }

    /// The page, and whether nothing it depends on moved while it was read (an agent can move refs during log).
    private func validatedHistory(
        key: HistoryKey, commonDirectory: URL
    ) async throws -> (
        commits: [GitCommit], valid: Bool
    ) {
        let commits = try await history(
            limit: key.limit, skip: 0, scope: key.scope,
            known: WalkTips.Known(references: key.references, head: key.head))
        async let refs = execute(GitArguments.referenceList)
        async let head = headCommit()
        let (validatedRefs, validatedHead) = try await (refs, head)
        let valid =
            validatedRefs.stdout == key.references && validatedHead == key.head
            && AncestryMetadata.identity(commonDirectory: commonDirectory) == key.ancestryMetadata
        return (commits, valid)
    }

    /// `origin`'s URL, else the current branch's remote, else the only remote, as configured with `insteadOf`
    /// applied (`git remote get-url`, which reads configuration only). Not sanitized: the caller keeps the HTTPS
    /// login hint before making the display form.
    private func snapshotRemoteURL(preferred: String, branch: String?) async throws -> String? {
        if !preferred.isEmpty { return preferred }
        if let branch, let name = try await configValue("branch." + branch + ".remote"), name != ".",
            let url = try await remoteGetURL(name)
        {
            return url
        }
        let names = try await execute(["remote"], outputLimit: 64 * 1_024).text.split(separator: "\n")
        guard names.count == 1 else { return nil }
        return try await remoteGetURL(String(names[0]))
    }

    /// Remote names in `urls` whose host resolves to github.com (including SSH host aliases).
    private func githubRemoteNames(
        in urls: [String: String], primary: String?, primaryResolved: Bool, resolver: GitHubRemoteResolver
    ) async -> Set<String> {
        var resolved: Set<String> = []
        var hostCache: [String: Bool] = [:]
        if primaryResolved, let primary, let host = RemoteAddress(primary)?.host { hostCache[host] = true }
        for (name, url) in urls {
            guard let host = RemoteAddress(url)?.host else { continue }
            if let cached = hostCache[host] {
                if cached { resolved.insert(name) }
                continue
            }
            let isGitHub = await resolver.resolve(url) != nil
            hostCache[host] = isGitHub
            if isGitHub { resolved.insert(name) }
        }
        return resolved
    }

    /// One remote's URL with `insteadOf` applied; nil for a name that could be read as an option or a missing remote.
    private func remoteGetURL(_ name: String) async throws -> String? {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 256, !GitInput.containsControlCharacters(name)
        else { return nil }
        let result = try await execute(["remote", "get-url", name], outputLimit: 64 * 1_024, allowFailure: true)
        let value = GitOutput.withoutTerminalLF(result.text)
        return result.exitCode == 0 && !value.isEmpty && !value.contains("\n") ? value : nil
    }

    /// One configuration value; nil when unset or empty.
    func configValue(_ key: String) async throws -> String? {
        let result = try await execute(["config", "--get", key], outputLimit: 64 * 1_024, allowFailure: true)
        let value = GitOutput.withoutTerminalLF(result.text)
        return result.exitCode == 0 && !value.isEmpty ? value : nil
    }
}

/// What one snapshot's history walk starts from.
private struct SnapshotWalk {
    var root: URL
    var gitDirectory: URL
    var common: URL
    var references: [GitReference]
    var key: HistoryKey
    var limit: Int

    /// The snapshot as far as the history goes: the current branch and HEAD as the references say, no working-tree
    /// changes, worktrees, stashes or remote yet.
    func preview(_ commits: [GitCommit]) -> RepositorySnapshot {
        let branch = references.first { $0.isCurrent && $0.kind == .branch }?.name
        return RepositorySnapshot(
            root: root, branch: branch, head: key.head, changes: [], commits: Array(commits.prefix(limit)),
            references: references, worktrees: [], stashes: [], remoteURL: nil, gitDirectory: gitDirectory,
            commonGitDirectory: common, hasMoreHistory: commits.count > limit,
            ancestryIdentity: key.ancestryMetadata + "|replacements:"
                + AncestryMetadata.replacementIdentity(key.references),
            operation: try? OperationStateReader.read(directory: gitDirectory, head: key.head), historyScope: key.scope,
            isPreview: true)
    }
}
