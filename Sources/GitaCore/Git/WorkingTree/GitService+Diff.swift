import Foundation

/// Diffs of working files, the index, commits and stashes, and the files a commit changed.
extension GitService {
    public func changedFiles(commit: String) async throws -> [FileChange] {
        let sha = try await resolveCommit(commit)
        let arguments =
            GitInput.isStashReference(commit)
            ? ["stash", "show", "--include-untracked", "--name-status", "-z"] + GitArguments.safeDiff
                + ["--find-renames", sha]
            : [
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "-M",
                "--diff-merges=first-parent",
                sha, "--",
            ]
        return GitParsers.changedFiles(try await execute(arguments).stdout)
    }

    /// `tracking` (from the last status) only chooses which diff to start alongside the tracked check, so the
    /// usual case costs one round trip instead of two; the check still decides which result is returned.
    public func diff(
        path: String?, staged: Bool = false, commit: String? = nil, stagedBase: String? = nil,
        tracking: TrackingGuess = .unknown
    ) async throws -> String {
        if let path { try GitInput.validatePath(path) }
        if let commit {
            let sha = try await resolveCommit(commit)
            if GitInput.isStashReference(commit) { return try await stashDiff(sha: sha, path: path) }
            return try await execute(
                ["show", "--format=", "--no-show-signature", "--diff-merges=first-parent", "--find-renames"]
                    + GitArguments.safeDiff + [sha, "--"] + (path.map { [$0] } ?? [])
            ).text
        }
        guard !staged, let path else {
            return String(
                decoding: try await indexDiff(path: path, staged: staged, stagedBase: stagedBase), as: UTF8.self)
        }
        return String(decoding: try await workingDiff(path: path, guess: tracking), as: UTF8.self)
    }

    /// The exact bytes of `git diff [--cached [base]] -- path`, or of an untracked file's diff against nothing.
    func indexDiff(path: String?, staged: Bool, stagedBase: String? = nil) async throws -> Data {
        if let path, !staged { return try await workingDiff(path: path, guess: .unknown) }
        if staged, let stagedBase { try GitInput.validateReference(stagedBase) }
        return try await execute(Self.trackedDiff(path: path, staged: staged, stagedBase: stagedBase)).stdout
    }

    /// What the last status said about a working-tree file, used only to start the likely diff early.
    public enum TrackingGuess: Sendable {
        case tracked, untracked, unknown
    }

    private func workingDiff(path: String, guess: TrackingGuess) async throws -> Data {
        async let tracked = execute(["ls-files", "--error-unmatch", "--", path], allowFailure: true)
        // Started speculatively; a guess that turns out wrong is cancelled when it goes out of scope unread.
        async let speculative = speculativeDiff(path: path, guess: guess)
        let check = try await tracked
        guard check.exitCode <= 1 else { throw Self.failure(check) }
        let isTracked = check.exitCode == 0
        if guess != .unknown, (guess == .tracked) == isTracked, let result = try await speculative {
            return try Self.diffOutput(result, untracked: !isTracked)
        }
        let result = try await execute(
            isTracked ? Self.trackedDiff(path: path, staged: false) : Self.untrackedDiff(path: path),
            allowFailure: true)
        return try Self.diffOutput(result, untracked: !isTracked)
    }

    private func speculativeDiff(path: String, guess: TrackingGuess) async throws -> CommandResult? {
        switch guess {
        case .tracked: try await execute(Self.trackedDiff(path: path, staged: false), allowFailure: true)
        case .untracked: try await execute(Self.untrackedDiff(path: path), allowFailure: true)
        case .unknown: nil
        }
    }

    /// `--no-index` exits 1 when there are differences; that is not a failure.
    private static func diffOutput(_ result: CommandResult, untracked: Bool) throws -> Data {
        guard result.exitCode == 0 || (untracked && result.exitCode == 1) else { throw failure(result) }
        return result.stdout
    }

    private static func trackedDiff(path: String?, staged: Bool, stagedBase: String? = nil) -> [String] {
        ["diff"] + GitArguments.safeDiff + ["--find-renames"]
            + (staged ? ["--cached"] + (stagedBase.map { [$0] } ?? []) : [])
            + ["--"] + (path.map { [$0] } ?? [])
    }

    /// Git handles symlinks as links here, never reading their targets.
    private static func untrackedDiff(path: String) -> [String] {
        ["diff", "--no-index"] + GitArguments.safeDiff + ["--", "/dev/null", path]
    }

    private func stashDiff(sha: String, path: String?) async throws -> String {
        let options =
            ["show", "--format=", "--no-show-signature", "--diff-merges=first-parent", "--find-renames"]
            + GitArguments.safeDiff
        let pathArguments = ["--"] + (path.map { [$0] } ?? [])
        async let tracked = execute(options + [sha] + pathArguments)
        let thirdParent = try await execute(["rev-parse", "--verify", "--quiet", sha + "^3"], allowFailure: true)
        var untracked = Data()
        if thirdParent.exitCode == 0 {
            let objectID = GitOutput.withoutTerminalLF(thirdParent.text)
            guard GitParsers.isObjectID(objectID) else { throw GitError.invalidReference }
            // stash show cannot filter paths. Its third parent is a root commit
            // containing the saved untracked files; show preserves NUL-safe argv paths.
            untracked = try await execute(options + [objectID] + pathArguments).stdout
        } else if thirdParent.exitCode != 1 {
            throw Self.failure(thirdParent)
        }
        let trackedResult = try await tracked
        guard trackedResult.stdout.count + untracked.count <= Self.hunkDiffLimit else {
            throw CommandError.outputLimitExceeded(Self.hunkDiffLimit)
        }
        return trackedResult.text + String(decoding: untracked, as: UTF8.self)
    }
}
