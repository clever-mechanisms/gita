import Foundation

/// Reflog inspection and recovery helpers (read reflog, detect orphaned commits, per-file diff, create branch).
extension GitService {
    private static let reflogOutputLimit = 16 * 1_024 * 1_024
    private static let reflogEntryCap = 1_000
    private static let reachabilityChunkSize = 100

    /// Loads reflog entries for `ref` (defaults to `HEAD`) and marks commits unreachable from any ref or `HEAD`.
    public func reflog(ref: String = "HEAD", limit: Int = 200) async throws -> [ReflogEntry] {
        try Task.checkCancellation()
        try GitInput.validateReference(ref)
        let clampedLimit = min(max(limit, 1), Self.reflogEntryCap)
        guard try await headCommit() != nil else { return [] }
        let result = try await execute(
            [
                "reflog", "show", "--no-show-signature", "-z",
                "--max-count=\(clampedLimit)",
                "--format=" + ReflogParser.format,
                ref,
                "--",
            ],
            outputLimit: Self.reflogOutputLimit,
            allowFailure: true
        )
        guard result.exitCode == 0 else {
            let diagnostic = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if diagnostic.contains("does not have any commits") || diagnostic.contains("unknown revision") {
                return []
            }
            throw Self.failure(result)
        }
        let rawEntries = ReflogParser.parse(result.stdout)
        guard !rawEntries.isEmpty else { return [] }
        let orphaned = try await unreachableCommits(in: rawEntries.map(\.commitID))
        guard !orphaned.isEmpty else { return rawEntries }
        return ReflogParser.parse(result.stdout, orphanedIDs: orphaned)
    }

    /// Returns the files changed by one reflog commit (including orphaned commits).
    public func reflogChangedFiles(commitID: String) async throws -> [FileChange] {
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        return try await changedFiles(commit: commitID)
    }

    /// Returns the unified diff of one file (or commit if `path` is nil) for a reflog commit.
    public func reflogCommitDiff(commitID: String, path: String? = nil) async throws -> String {
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        return try await diff(path: path, commit: commitID)
    }

    /// Creates and checks out a new local branch at a reflog commit to rescue or revisit it.
    public func createBranchFromReflog(name: String, commitID: String) async throws {
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        try await createBranch(name: name, from: commitID)
    }

    /// Determines which of `commitIDs` are unreachable from all refs (`--all`, including remotes/stashes/notes) and
    /// `HEAD` (including linked worktrees' detached HEADs). Batched to prevent argv overflow on large reflogs.
    private func unreachableCommits(in commitIDs: [String]) async throws -> Set<String> {
        let unique = Array(Set(commitIDs).filter(GitParsers.isObjectID))
        guard !unique.isEmpty else { return [] }
        let extraHeads = await worktreeHeadCommits()
        var orphaned: Set<String> = []
        var offset = 0
        while offset < unique.count {
            try Task.checkCancellation()
            let end = min(offset + Self.reachabilityChunkSize, unique.count)
            let chunk = Array(unique[offset..<end])
            let arguments = ["rev-list"] + chunk + ["--not", "--all", "HEAD"] + extraHeads
            if let result = try? await execute(arguments, outputLimit: Self.reflogOutputLimit, allowFailure: true),
                result.exitCode == 0
            {
                let unreachable = Set(GitOutput.lines(result.text))
                orphaned.formUnion(Set(chunk).intersection(unreachable))
            }
            offset = end
        }
        return orphaned
    }

    private func worktreeHeadCommits() async -> [String] {
        guard let result = try? await execute(["worktree", "list", "--porcelain", "-z"], allowFailure: true),
            result.exitCode == 0
        else { return [] }
        let heads = GitParsers.worktrees(result.stdout).map(\.head).filter(GitParsers.isObjectID)
        return Array(Set(heads))
    }
}
