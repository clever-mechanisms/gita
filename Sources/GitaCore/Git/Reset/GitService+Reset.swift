import Foundation

/// Reset HEAD (soft, mixed or hard) to a reviewed commit, only if nothing the review covered has changed.
extension GitService {
    static let resetListingLimit = 64 * 1_024 * 1_024
    static let indexFileLimit = 64 * 1_024 * 1_024

    public func resetPreview(to commitID: String) async throws -> GitResetPreview {
        try await loadResetReview(commitID).preview
    }

    public func reset(_ expected: GitResetPreview, mode: GitResetMode) async throws {
        try await mutate { service in
            let current = try await service.loadResetReview(expected.target.id)
            guard current.preview.identity == expected.identity else {
                throw ResetError.reviewChanged
            }
            if mode == .hard { try HardResetSafety(review: current).check() }
            try Task.checkCancellation()
            // One porcelain operation owns HEAD, ORIG_HEAD, index locking and
            // worktree updates. No app-generated sequence or recursive reset.
            _ = try await service.managementCommand(
                current.options + GitArguments.noHooks + [
                    "-c", "commit.gpgsign=false", "reset", "--" + mode.rawValue, "--no-recurse-submodules",
                    current.preview.target.id, "--",
                ],
                timeout: 120, outputLimit: 1_024 * 1_024, mutation: true,
                failure: ResetError.finishFailed)
        }
    }

    private func loadResetReview(_ commitID: String) async throws -> ResetReview {
        try Task.checkCancellation()
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        let options = try await localObjectOptions()
        let root = try await repositoryRoot()
        let gitDirectory = URL(fileURLWithPath: try await gitDirectories().gitDirectory).resolvingSymlinksInPath()
        let state = try await resetState(options: options, gitDirectory: gitDirectory)
        let target = try await resetTarget(commitID, options: options)
        let inputs = try await resetInputs(commitID, options: options, root: root, headID: state.headID)
        var identity = Fingerprint()
        identity.add("root", root.path)
        identity.add("git-directory", gitDirectory.path)
        identity.add("target", commitID)
        state.add(to: &identity)
        inputs.add(to: &identity)
        try WorkingTreeFingerprint.add(root: root, paths: inputs.trackedPaths, to: &identity)
        guard try await resetState(options: options, gitDirectory: gitDirectory) == state else {
            throw ResetError.changedWhilePreparing
        }
        let caseSensitive =
            (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames)
            ?? false
        let changes = GitParsers.status(inputs.status).changes
        let preview = GitResetPreview(
            target: target, currentHeadID: state.headID,
            currentBranch: state.branch.map { $0.dropPrefix(GitReference.Kind.branch.prefix) ?? $0 },
            trackedChangeCount: changes.filter { !$0.isUntracked }.count,
            untrackedFileCount: changes.filter(\.isUntracked).count, identity: identity.hex)
        return ResetReview(
            preview: preview, options: options, index: inputs.index, target: inputs.target,
            otherPaths: inputs.otherPaths, status: inputs.status, caseSensitive: caseSensitive)
    }

    /// HEAD, its branch, replacement refs and the index file: read before and after the review, which is refused
    /// when any of them moved in between.
    private func resetState(options: [String], gitDirectory: URL) async throws -> ResetState {
        let head = try await managementCommand(
            options + ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], outputLimit: 4_096,
            failure: ResetError.noHead)
        let headID = GitOutput.withoutTerminalLF(head.text)
        guard GitParsers.isObjectID(headID),
            try OperationStateReader.read(directory: gitDirectory, head: headID) == nil,
            !FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("BISECT_START").path)
        else { throw GitError.operationActive }
        let symbolic = try await managementCommand(
            ["symbolic-ref", "--quiet", "HEAD"], outputLimit: 64 * 1_024, allowed: [0, 1])
        let replacements = try await managementCommand(GitArguments.replacementList)
        let index = try BoundedFile.contents(gitDirectory.appendingPathComponent("index"), limit: Self.indexFileLimit)
        return ResetState(
            head: head.stdout, headID: headID, symbolic: symbolic.stdout,
            branch: symbolic.exitCode == 0 ? GitOutput.withoutTerminalLF(symbolic.text) : nil,
            replacements: replacements.stdout, index: index ?? Data())
    }

    private func resetTarget(_ commitID: String, options: [String]) async throws -> GitCommit {
        let result = try await managementCommand(
            options + [
                "show", "--no-patch", "--no-show-signature", "--decorate=short", "-z",
                "--format=" + GitArguments.commitFormat, commitID, "--",
            ],
            outputLimit: 1_024 * 1_024, failure: ResetError.fullCommitID)
        let commits = GitParsers.commits(result.stdout)
        guard commits.count == 1, let target = commits.first, target.id == commitID else {
            throw GitError.invalidReference
        }
        return target
    }

    /// Untracked and ignored paths are listed per directory (`--directory`): an ignored tree with many files is one
    /// entry, and a collision with a whole directory is still found.
    private func resetInputs(
        _ commitID: String, options: [String], root: URL, headID: String
    ) async throws -> ResetInputs {
        let limit = Self.resetListingLimit
        async let shared = managementCommand(options + ["rev-parse", "--shared-index-path"], outputLimit: 64 * 1_024)
        async let staged = managementCommand(options + ["ls-files", "--stage", "-z", "--"], outputLimit: limit)
        async let headTree = managementCommand(
            options + ["ls-tree", "-r", "-z", "--full-tree", headID], outputLimit: limit)
        async let targetTree = managementCommand(
            options + ["ls-tree", "-r", "-z", "--full-tree", commitID], outputLimit: limit)
        async let status = managementCommand(
            options + ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignore-submodules=none"],
            outputLimit: limit)
        async let other = managementCommand(
            options + ["ls-files", "--others", "--directory", "-z", "--"], outputLimit: limit)
        let sharedPath = GitOutput.withoutTerminalLF(try await shared.text)
        let sharedIndex =
            sharedPath.isEmpty
            ? nil
            : try BoundedFile.contents(URL(fileURLWithPath: sharedPath, relativeTo: root), limit: Self.indexFileLimit)
        return try await ResetInputs(
            sharedIndex: sharedIndex ?? Data(), staged: staged.stdout, headTree: headTree.stdout,
            targetTree: targetTree.stdout, status: status.stdout, other: other.stdout)
    }
}
