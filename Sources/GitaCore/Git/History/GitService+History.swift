import Foundation

/// History pages, commit details and comparisons. All read-only.
extension GitService {
    static let historyPageLimit = 10_001
    static let historyOutputLimit = 16 * 1_024 * 1_024

    /// A page of the history. A page right after the previous one continues that walk (`HistoryStream`).
    public func history(limit: Int, skip: Int, scope: HistoryScope = .all) async throws -> [GitCommit] {
        if skip > 0, let snapshot = history.entry?.key, snapshot.scope == scope, runner is CommandRunner {
            return try await streamedHistory(limit: limit, skip: skip, scope: scope, snapshot: snapshot)
        }
        return try await history(limit: limit, skip: skip, scope: scope, known: nil)
    }

    /// `known`: the reference listing and HEAD just read (`walkRevisions`). When its tips still have to be reduced,
    /// Git's own revisions and the reduced tips race (`racedPage`).
    func history(limit: Int, skip: Int, scope: HistoryScope, known: WalkTips.Known?) async throws -> [GitCommit] {
        // --all includes HEAD, including a detached HEAD; an unborn repository returns an empty list.
        let start = ContinuousClock.now
        startWalk(start)
        defer { noteWalk(ContinuousClock.now - start, start: start) }
        let page = Self.page(limit: limit, skip: try Self.gitSkip(skip))
        switch try await walkPlan(scope, known: known) {
        case .walk(let revisions): return try await logPage(page, from: revisions)
        case .reduce(let tips, let key): return try await racedPage(page, scope: scope, tips: tips, key: key)
        }
    }

    private func logPage(_ page: [String], from revisions: [String]) async throws -> [GitCommit] {
        let result = try await execute(
            GitArguments.logRecord + page + revisions + ["--"], outputLimit: Self.historyOutputLimit)
        return GitParsers.commits(result.stdout)
    }

    /// The first walk for these references: from Git's own revisions, and from the independent tips once they are
    /// known; the first to finish is the page (both print the same commits: Git starts from its tips by date).
    /// Walking from the tips pays where old tags would make Git count through the whole history (Linux: 0.09 s
    /// against 0.83 s), Git's own revisions where finding the tips costs more than it saves (LLVM). The reduction
    /// always finishes, for the pages after, but the page does not wait for it.
    private func racedPage(
        _ page: [String], scope: HistoryScope, tips: [String], key: WalkTips.Key
    ) async throws -> [GitCommit] {
        let reduction = Task { try await self.reduce(tips, key: key, scope: scope) }
        return try await withThrowingTaskGroup(of: [GitCommit]?.self) { group in
            group.addTask { try await self.logPage(page, from: scope.revisions) }
            group.addTask {
                guard let revisions = await Self.unlessCancelled(reduction), revisions != scope.revisions else {
                    return nil
                }
                return try await self.logPage(page, from: revisions)
            }
            while let result = try await group.next() {
                guard let result else { continue }
                group.cancelAll()
                return result
            }
            throw CancellationError()
        }
    }

    /// `task`'s value, or nil once it fails or the caller is cancelled first; the task itself runs on.
    static func unlessCancelled<T: Sendable>(_ task: Task<T, any Error>) async -> T? {
        let gate = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.set(continuation)
                Task { gate.resume(with: try? await task.value) }
            }
        } onCancel: {
            gate.resume(with: nil)
        }
    }

    /// Page the ancestry of the exact reviewed commit, including every merge
    /// parent. A moving branch or tag cannot change this view's starting point.
    public func history(from commitID: String, limit: Int, skip: Int) async throws -> [GitCommit] {
        try Task.checkCancellation()
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        let offset = try Self.gitSkip(skip)
        let options = try await localObjectOptions()
        let resolved = try await execute(
            options + ["rev-parse", "--verify", "--quiet", "--end-of-options", commitID + "^{commit}"],
            timeout: 10, outputLimit: 4_096, allowFailure: true)
        // Besides rejecting non-commits, exact equality rejects a tag object or
        // a 40-character abbreviation in a repository using SHA-256 objects.
        guard resolved.exitCode == 0, GitOutput.same(GitOutput.withoutTerminalLF(resolved.text), commitID) else {
            throw GitError.invalidReference
        }
        let result = try await execute(
            options + GitArguments.logRecord + Self.page(limit: limit, skip: offset) + [commitID, "--"],
            timeout: 30, outputLimit: Self.historyOutputLimit)
        try Task.checkCancellation()
        return GitParsers.commits(result.stdout)
    }

    /// Git's revision parser stores --skip in a signed int: a larger Swift Int must not wrap into a different page.
    static func gitSkip(_ skip: Int) throws -> Int {
        guard skip <= Int(Int32.max) else { throw CommandError.invalidArgument }
        return max(0, skip)
    }

    static func page(limit: Int, skip: Int) -> [String] {
        ["--max-count=\(min(max(limit, 1), historyPageLimit))", "--skip=\(skip)"]
    }

    public func commitDetails(ref: String) async throws -> CommitDetails {
        try GitInput.validateReference(ref)
        let local = try await localObjectOptions()
        let resolved = try await execute(
            local + ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], timeout: 15, outputLimit: 4_096)
        let sha = GitOutput.withoutTerminalLF(resolved.text)
        guard GitParsers.isObjectID(sha) else { throw GitError.invalidReference }
        let format = GitArguments.commitFormat + "%x00%cn%x00%ce%x00%ct%x00%B"
        let output = try await execute(
            local + [
                "-c", "i18n.logOutputEncoding=UTF-8", "show", "--no-patch", "--no-show-signature", "--decorate=short",
                "-z", "--format=" + format, sha, "--",
            ])
        let fields = output.text.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count == 12, let commit = GitParsers.commits(output.stdout).first, Double(fields[9]) != nil
        else { throw GitError.invalidReference }
        return CommitDetails(commit: commit, message: String(fields[10]), committer: String(fields[7]))
    }

    /// Commits reachable from `head` but not from `base` (`git rev-list --count base..head`); nil when either is not
    /// in local history. Read-only.
    public func commitCount(from base: String, to head: String) async -> Int? {
        guard let from = try? await resolveCommit(base, verify: true),
            let to = try? await resolveCommit(head, verify: true),
            let result = try? await execute(
                ["rev-list", "--count", from + ".." + to, "--"], timeout: 15, outputLimit: 64)
        else { return nil }
        return Int(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func compareFiles(base: String, head: String) async throws -> [FileChange] {
        let (from, to) = try await resolvePair(base, head)
        let result = try await execute(
            ["diff", "--name-status", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", from, to, "--"])
        return GitParsers.changedFiles(result.stdout)
    }

    public func compareDiff(base: String, head: String, path: String?) async throws -> String {
        if let path { try GitInput.validatePath(path) }
        let (from, to) = try await resolvePair(base, head)
        return try await execute(
            ["diff"] + GitArguments.safeDiff + ["--find-renames", from, to, "--"] + (path.map { [$0] } ?? [])
        ).text
    }

    private func resolvePair(_ base: String, _ head: String) async throws -> (String, String) {
        async let baseID = resolveCommit(base, verify: true)
        async let headID = resolveCommit(head, verify: true)
        return try await (baseID, headID)
    }
}
