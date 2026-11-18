import Foundation

extension GitService {
    public func previewInteractiveRebase(after commitID: String) async throws -> GitInteractiveRebasePlan {
        try await loadRebaseReview(after: commitID).plan
    }

    public func startInteractiveRebase(
        _ expected: GitInteractiveRebasePlan, steps: [GitRebaseStep]
    ) async throws -> GitOperationOutcome {
        try RebaseSession.validateSteps(steps, originalIDs: expected.commits.map(\.id))
        return try await mutate { service in
            let actual = try await service.loadRebaseReview(after: expected.base.id)
            guard actual.plan.identity == expected.identity, actual.plan.headID == expected.headID,
                actual.plan.branch == expected.branch, actual.plan.commits.map(\.id) == expected.commits.map(\.id)
            else {
                throw RebasePlanError.staleReview
            }
            let session = try RebaseSession.create(actual, steps: steps)
            return try await service.runInteractiveRebase(
                session,
                arguments: [
                    "rebase", "--interactive", "--merge", "--force-rebase", "--no-autostash", "--no-autosquash",
                    "--no-update-refs", "--no-fork-point", "--no-rebase-merges", "--reapply-cherry-picks",
                    "--keep-empty", "--empty=stop", "--strategy=ort", "--no-gpg-sign", "--no-verify", "--",
                    actual.plan.base.id,
                ])
        }
    }

    /// Called only inside the existing mutation gate, after its UI operation
    /// identity check. An external rebase retains the existing generic behavior.
    func resumeInteractiveRebaseIfOwned(_ arguments: [String]) async throws -> GitOperationOutcome? {
        guard arguments.first == "rebase", arguments.count == 2 else { return nil }
        let result = try await execute(["rev-parse", "--absolute-git-dir"], timeout: 5, outputLimit: 64 * 1_024)
        let directory = try Self.physicalDirectory(GitOutput.withoutTerminalLF(result.text))
        let session: RebaseSession?
        do { session = try RebaseSession.active(directory: directory) } catch {
            // Abort does not execute the todo or an editor. Even damaged session
            // metadata must not prevent the user from restoring Git's original HEAD.
            if arguments.last == "--abort" { return try await runInteractiveRebase(nil, arguments: arguments) }
            throw error
        }
        guard let session else {
            // An interrupted start has no approved sequence marker yet. Never
            // treat its orphan manifest as authorization to run a different todo.
            let pending: RebaseSession?
            do { pending = try RebaseSession.pending(directory: directory) } catch {
                if arguments.last == "--abort" { return try await runInteractiveRebase(nil, arguments: arguments) }
                throw error
            }
            if let pending {
                guard arguments.last == "--abort" else {
                    throw RebaseEditorError.notPrepared
                }
                return try await runInteractiveRebase(pending, arguments: arguments)
            }
            return nil
        }
        if arguments.last != "--abort" {
            try session.validateRemaining()
            let options = try await localObjectOptions()
            let common = try await execute(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 5, outputLimit: 64 * 1_024)
            _ = try await rebaseAncestry(
                directory: directory, common: URL(fileURLWithPath: GitOutput.withoutTerminalLF(common.text)),
                options: options)
        }
        return try await runInteractiveRebase(session, arguments: arguments)
    }

    private func runInteractiveRebase(
        _ session: RebaseSession?, arguments: [String]
    ) async throws -> GitOperationOutcome {
        let local = try await localObjectOptions()
        let settings =
            [
                "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.editor=true", "sequence.editor=true",
                "rebase.backend=merge", "rebase.autoStash=false", "rebase.autoSquash=false", "rebase.updateRefs=false",
                "rebase.abbreviateCommands=false", "rebase.instructionFormat=%s", "rebase.missingCommitsCheck=error",
                "rebase.rescheduleFailedExec=false", "commit.gpgSign=false", "commit.cleanup=strip",
                "rerere.enabled=false",
                "rerere.autoupdate=false", "submodule.recurse=false", "gc.auto=0", "maintenance.auto=false",
                "i18n.commitEncoding=UTF-8", "i18n.logOutputEncoding=UTF-8",
            ]
            + (session.map {
                ["core.commentString=" + $0.manifest.commentPrefix, "core.abbrev=\($0.manifest.headID.count)"]
            } ?? [])
        let options = local + settings.flatMap { ["-c", $0] }
        let result: CommandResult
        do {
            result = try await execute(
                options + arguments, timeout: .untilIdle, outputLimit: 4 * 1_024 * 1_024, allowFailure: true,
                mutation: true, editors: try session?.editors())
        } catch let operationError {
            // Cancellation/timeouts leave a real native stop resumable. Remove
            // only our files after confirming Git left no operation behind.
            // An unreadable stop is not evidence that the operation has ended.
            if let session {
                do {
                    if try OperationStateReader.read(directory: session.directory, head: nil) == nil {
                        try? session.cleanup()
                    }
                } catch {
                    // Preserve the session for a later read or abort.
                }
            }
            throw operationError
        }
        if let state = try await operationState() {
            let message =
                state.isEditingCommit
                ? String(localized: "Stage changes, then continue to amend this commit.")
                : (result.exitCode == 0
                    ? String(localized: "Review the stopped commit, then continue.")
                    : Self.failure(result).localizedDescription)
            return .stopped(state, message)
        }
        try session?.cleanup()
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return .completed
    }
}
