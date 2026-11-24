import Foundation

/// Index and working-file changes: stage, unstage, discard, restore from a commit, and one hunk at a time.
extension GitService {
    static let hunkDiffLimit = 8 * 1_024 * 1_024

    public func stage(paths: [String]) async throws {
        try GitInput.validatePaths(paths)
        guard !paths.isEmpty else { return }
        try await mutate(["add", "--"] + paths)
    }

    /// A rename is unstaged as a whole: both its paths go back to `source` (or HEAD's index entries when nil).
    public func unstage(paths: [String], source: String? = nil) async throws {
        try GitInput.validatePaths(paths)
        if let source { try GitInput.validateReference(source) }
        guard !paths.isEmpty else { return }
        try await mutate { service in
            let changes =
                if let source {
                    try await service.stagedChanges(against: source)
                } else {
                    GitParsers.status(try await service.execute(GitArguments.trackedStatus).stdout).changes
                }
            var expanded = Set(paths)
            for change in changes {
                if let original = change.originalPath, expanded.contains(change.path) || expanded.contains(original) {
                    expanded.insert(original)
                    expanded.insert(change.path)
                }
            }
            let targets = expanded.sorted()
            if let source {
                _ = try await service.execute(
                    ["restore", "--staged", "--source", source, "--"] + targets, mutation: true)
            } else if try await service.headCommit() != nil {
                _ = try await service.execute(["restore", "--staged", "--"] + targets, mutation: true)
            } else {
                _ = try await service.execute(
                    ["rm", "--cached", "--ignore-unmatch", "-r", "--"] + targets, mutation: true)
            }
        }
    }

    /// Throws away unstaged changes: tracked files go back to their staged content, untracked files are deleted.
    /// An intent-to-add entry (`git add -N`) has no staged content, so it is deleted like an untracked file.
    public func discard(paths: [String]) async throws {
        try GitInput.validatePaths(paths)
        guard !paths.isEmpty else { return }
        try await mutate { service in
            let status = GitParsers.status(
                try await service.execute(["status", "--porcelain=v2", "-z", "--untracked-files=all"]).stdout)
            let wanted = Set(paths)
            let selected = status.changes.filter { wanted.contains($0.path) }
            let untracked = Set(selected.filter { $0.worktreeCode == .untracked }.map(\.path))
            let intentToAdd = Set(
                selected.filter { $0.indexCode == .unmodified && $0.worktreeCode == .added }.map(\.path))
            let tracked = paths.filter { !untracked.contains($0) && !intentToAdd.contains($0) }
            if !tracked.isEmpty { _ = try await service.execute(["checkout", "--"] + tracked, mutation: true) }
            if !intentToAdd.isEmpty {
                _ = try await service.execute(["rm", "-f", "-q", "--"] + intentToAdd.sorted(), mutation: true)
            }
            if !untracked.isEmpty {
                _ = try await service.execute(["clean", "-f", "-q", "--"] + untracked.sorted(), mutation: true)
            }
        }
    }

    /// Puts each path back to its content in `commit`, in the index and the working tree (Reset File to State at
    /// Commit); a path the commit does not have is removed.
    public func restore(paths: [String], from commit: String) async throws {
        try GitInput.validatePaths(paths)
        guard !paths.isEmpty else { return }
        let sha = try await resolveCommit(commit)
        try await mutate { service in
            var present: [String] = []
            var absent: [String] = []
            for path in paths {
                let exists = try await service.execute(["cat-file", "-e", sha + ":" + path], allowFailure: true)
                if exists.exitCode == 0 { present.append(path) } else { absent.append(path) }
            }
            if !present.isEmpty { _ = try await service.execute(["checkout", sha, "--"] + present, mutation: true) }
            if !absent.isEmpty {
                _ = try await service.execute(["rm", "-f", "-q", "--ignore-unmatch", "--"] + absent, mutation: true)
            }
        }
    }

    /// Stages (or, with `staged`, unstages) one hunk of the reviewed diff. The diff must still be byte-identical
    /// and valid UTF-8: the patch is rebuilt from text, so other bytes could not reach the index unchanged.
    public func applyHunk(
        path: String, staged: Bool, expectedDiff: String, hunkIndex: Int, stagedBase: String? = nil,
        options: DiffOptions = .standard
    ) async throws {
        try await mutate { service in
            let document = try await service.validatedDiffDocument(
                path: path, staged: staged, expectedDiff: expectedDiff, stagedBase: stagedBase, options: options)
            guard let hunk = document.hunks.first(where: { $0.index == hunkIndex }), !hunk.patch.isEmpty else {
                throw GitError.unsupportedHunk
            }
            try await service.applyPatch(
                Data(hunk.patch.utf8), cached: true, reverse: staged, unidiffZero: options.context == 0)
        }
    }

    /// Stages (or, with `staged`, unstages) only the selected rows of a reviewed diff.
    public func applyLines(
        path: String, staged: Bool, expectedDiff: String, selectedRows: IndexSet, stagedBase: String? = nil,
        options: DiffOptions = .standard
    ) async throws {
        try await mutate { service in
            let document = try await service.validatedDiffDocument(
                path: path, staged: staged, expectedDiff: expectedDiff, stagedBase: stagedBase, options: options)
            guard
                let patch = UnifiedDiff.patch(
                    document: document, selecting: selectedRows, mode: staged ? .unstage : .stage)
            else {
                throw GitError.unsupportedHunk
            }
            try await service.applyPatch(
                Data(patch.utf8), cached: true, reverse: staged, unidiffZero: options.context == 0)
        }
    }

    func validatedDiffDocument(
        path: String, staged: Bool, expectedDiff: String, stagedBase: String?, options: DiffOptions
    ) async throws -> DiffDocument {
        try GitInput.validatePath(path)
        if staged, let stagedBase { try GitInput.validateReference(stagedBase) }
        guard !options.ignoreWhitespace else { throw GitError.unsupportedHunk }
        guard expectedDiff.utf8.count <= Self.hunkDiffLimit else {
            throw CommandError.outputLimitExceeded(Self.hunkDiffLimit)
        }
        let currentBytes = try await indexDiff(
            path: path, staged: staged, stagedBase: staged ? stagedBase : nil, options: options)
        guard let current = String(data: currentBytes, encoding: .utf8) else { throw GitError.unsupportedHunk }
        // String equality normalizes Unicode. This guard must compare the exact
        // reviewed bytes, including composed/decomposed text and line endings.
        guard GitOutput.same(current, expectedDiff) else { throw GitError.staleDiff }
        let document = UnifiedDiff.parse(current)
        guard document.canApplyHunks else { throw GitError.unsupportedHunk }
        return document
    }

    func applyPatch(_ patch: Data, cached: Bool, reverse: Bool, unidiffZero: Bool = false) async throws {
        let prefix = cached ? "GitaPatch" : "GitaDiscardPatch"
        let temporary = try PrivateTemporaryDirectory.make(
            prefix: prefix, failure: LocalFileError.temporaryPatchNotCreated)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("hunk.patch")
        try patch.write(to: file, options: .withoutOverwriting)
        let options =
            ["apply"] + (cached ? ["--cached"] : []) + (reverse ? ["--reverse"] : [])
            + (unidiffZero ? ["--unidiff-zero"] : []) + ["--whitespace=nowarn"]
        _ = try await execute(options + ["--check", "--", file.path])
        try Task.checkCancellation()
        // --cached changes only the index; Git takes its index.lock atomically.
        _ = try await execute(options + ["--", file.path], mutation: true)
    }
}
