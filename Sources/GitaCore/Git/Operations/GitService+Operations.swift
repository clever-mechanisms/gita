import Foundation

/// Merge, rebase, cherry-pick and revert, and continuing, skipping or aborting the stopped one.
extension GitService {
    public func operationState() async throws -> GitOperationState? { try await operationContext().state }

    func operationContext() async throws -> (state: GitOperationState?, head: String?) {
        async let directory = execute(["rev-parse", "--absolute-git-dir"])
        async let head = headCommit()
        let (directoryResult, headID) = try await (directory, head)
        let gitDirectory = URL(fileURLWithPath: GitOutput.withoutTerminalLF(directoryResult.text))
        return (try OperationStateReader.read(directory: gitDirectory, head: headID), headID)
    }

    public func merge(ref: String, mode: GitMergeMode = .automatic) async throws -> GitOperationOutcome {
        try await mutate { service in
            try await service.requireCleanOperationStart()
            let sha = try await service.resolveCommit(ref, verify: true)
            return try await service.runOperation([
                "merge", "--no-edit", "--commit", "--no-squash", "--no-autostash", mode.flag, sha,
            ])
        }
    }

    public func rebase(onto ref: String) async throws -> GitOperationOutcome {
        try await mutate { service in
            try await service.requireCleanOperationStart()
            let sha = try await service.resolveCommit(ref, verify: true)
            return try await service.runOperation([
                "rebase", "--merge", "--no-autostash", "--no-autosquash",
                "--no-update-refs", "--no-fork-point", "--no-rebase-merges", sha,
            ])
        }
    }

    public func cherryPick(commit: String, mainline: Int? = nil) async throws -> GitOperationOutcome {
        try await applyCommitOperation("cherry-pick", commit: commit, mainline: mainline)
    }

    public func revert(commit: String, mainline: Int? = nil) async throws -> GitOperationOutcome {
        try await applyCommitOperation("revert", commit: commit, mainline: mainline)
    }

    /// A merge commit needs an explicit mainline parent; any other commit must not get one.
    private func applyCommitOperation(
        _ command: String, commit: String, mainline: Int?
    ) async throws -> GitOperationOutcome {
        try await mutate { service in
            try await service.requireCleanOperationStart()
            let details = try await service.commitDetails(ref: commit)
            let parents = details.commit.parents.count
            if parents > 1 {
                guard let mainline, (1...parents).contains(mainline) else {
                    throw OperationError.mainlineRequired
                }
            } else if mainline != nil {
                throw OperationError.mainlineNotNeeded
            }
            return try await service.runOperation(
                [command, "--no-edit"] + (mainline.map { ["--mainline", String($0)] } ?? []) + [details.commit.id])
        }
    }

    public func continueOperation(expected: GitOperationState) async throws -> GitOperationOutcome {
        try await mutate { service in
            let state = try await service.requireOperation(expected)
            guard try await service.unmergedIndex().isEmpty else { throw GitError.unresolvedConflicts }
            return try await service.runOperation([state.kind.command, "--continue"])
        }
    }

    public func skipOperation(expected: GitOperationState) async throws -> GitOperationOutcome {
        try await mutate { service in
            let state = try await service.requireOperation(expected)
            guard state.canSkip else {
                throw OperationError.mergeCannotBeSkipped
            }
            return try await service.runOperation([state.kind.command, "--skip"])
        }
    }

    public func abortOperation(expected: GitOperationState) async throws -> GitOperationOutcome {
        try await mutate { service in
            let state = try await service.requireOperation(expected)
            return try await service.runOperation([state.kind.command, "--abort"])
        }
    }

    private func requireOperation(_ expected: GitOperationState) async throws -> GitOperationState {
        guard let actual = try await operationState(), actual.kind == expected.kind,
            actual.identity == expected.identity
        else { throw GitError.operationChanged }
        return actual
    }

    func requireNoOperation() async throws {
        guard try await operationState() == nil else { throw GitError.operationActive }
        guard try await unmergedIndex().isEmpty else { throw GitError.unresolvedConflicts }
    }

    func requireCleanOperationStart() async throws {
        try await requireNoOperation()
        guard try await hasCleanTrackedFiles() else { throw GitError.dirtyTrackedFiles }
    }

    func hasCleanTrackedFiles(options: [String] = []) async throws -> Bool {
        GitParsers.status(try await execute(options + GitArguments.trackedStatus).stdout).changes.isEmpty
    }

    func unmergedIndex(path: String? = nil) async throws -> Data {
        let local = try await localObjectOptions()
        return try await execute(local + ["ls-files", "--unmerged", "--stage", "-z", "--"] + (path.map { [$0] } ?? []))
            .stdout
    }

    func runOperation(_ arguments: [String]) async throws -> GitOperationOutcome {
        if let outcome = try await resumeInteractiveRebaseIfOwned(arguments) { return outcome }
        let result = try await execute(
            GitArguments.configOptions(GitArguments.operationOverrides) + arguments, timeout: .untilIdle,
            allowFailure: true, mutation: true)
        if let state = try await operationState() {
            let diagnostic = result.stderr.isEmpty ? result.stdout : result.stderr
            let message =
                diagnostic.isEmpty
                ? String(localized: "Resolve the pending changes, then continue.")
                : Self.failure(CommandResult(stdout: Data(), stderr: diagnostic, exitCode: result.exitCode))
                    .localizedDescription
            return .stopped(state, message)
        }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return .completed
    }
}
