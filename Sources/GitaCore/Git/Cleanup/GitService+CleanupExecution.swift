import Foundation

extension GitService {
    public func executeCleanup(_ selection: CleanupBatchSelection) async throws -> CleanupBatchResult {
        try await mutate { service in
            try await service.requireNoOperation()
            var result = CleanupBatchResult()
            for name in selection.branches.keys.sorted() {
                try Task.checkCancellation()
                guard let expected = selection.branches[name] else { continue }
                do {
                    try await service.deleteCleanupBranch(
                        name, expectedCommit: expected, allowUnmerged: selection.allowUnmergedBranchDelete)
                    result.deletedBranches.append(name)
                } catch {
                    result.failures.append(CleanupItemFailure(target: name, reason: error.localizedDescription))
                }
            }
            for path in selection.worktreePaths {
                try Task.checkCancellation()
                do {
                    try await service.removeCleanupWorktree(path)
                    result.removedWorktrees.append(path)
                } catch {
                    result.failures.append(CleanupItemFailure(target: path, reason: error.localizedDescription))
                }
            }
            return result
        }
    }

    private func removeCleanupWorktree(_ path: String) async throws {
        let inventory = try await workflowBranches()
        guard inventory.removableWorktrees.contains(where: { GitOutput.same($0.path, path) }) else {
            throw GitError.referenceInUse
        }
        if FileManager.default.fileExists(atPath: path), try await cleanupWorktreeIsDirty(path) {
            throw GitError.commandFailed(String(localized: "Commit or stash the changes in this worktree first."))
        }
        _ = try await execute(["worktree", "remove", "--", path], mutation: true)
    }

    private func deleteCleanupBranch(_ name: String, expectedCommit: String, allowUnmerged: Bool) async throws {
        guard GitParsers.isObjectID(expectedCommit) else { throw GitError.invalidReference }
        let inventory = try await workflowBranches()
        guard !inventory.protectedNames.contains(name) else { throw GitError.referenceInUse }
        guard let ref = inventory.refs.first(where: { $0.name == name }) else { throw GitError.invalidReference }
        guard ref.commit == expectedCommit else { throw GitError.staleReference }
        let merged = try await isAncestor(ref.commit, of: inventory.mergeTarget)
        guard merged || allowUnmerged else { throw GitError.branchNotMerged }
        // Ancestry against `mergeTarget` and the scanned commit OID were just verified under the mutation gate;
        // `-d` checks HEAD/upstream instead of `mergeTarget` and rejects merged branches from other checkouts.
        _ = try await execute(["branch", "-D", "--", name], mutation: true)
    }
}
