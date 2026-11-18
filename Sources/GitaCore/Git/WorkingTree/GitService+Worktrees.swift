import Foundation

/// Linked worktrees and stashes.
extension GitService {
    public func addWorktree(path: URL, branch: String) async throws {
        try await mutate { service in
            try await service.validateBranch(branch)
            try await service.requireOtherWorktree(path)
            let exists = try await service.execute(
                ["show-ref", "--verify", "--quiet", "refs/heads/" + branch], allowFailure: true)
            let arguments =
                exists.exitCode == 0
                ? ["worktree", "add", "--", path.path, branch]
                : ["worktree", "add", "-b", branch, "--", path.path, "HEAD"]
            _ = try await service.execute(arguments, mutation: true)
        }
    }

    /// Git refuses the main worktree, dirty trees, locked trees, and untracked files. Removal is never forced.
    public func removeWorktree(path: URL) async throws {
        try await requireOtherWorktree(path)
        try await mutate(["worktree", "remove", "--", path.path])
    }

    private func requireOtherWorktree(_ path: URL) async throws {
        let currentRoot = try await repositoryRoot()
        guard path.isFileURL, !path.path.contains("\0"), path.resolvingSymlinksInPath() != currentRoot else {
            throw GitError.invalidPath
        }
    }

    public func stash(message: String) async throws {
        guard !message.contains("\0") else { throw CommandError.invalidArgument }
        try await mutate(["stash", "push", "--include-untracked", "-m", message.isEmpty ? "Gita" : message])
    }

    public func applyStash(ref: String) async throws {
        guard GitInput.isStashReference(ref) else { throw GitError.invalidReference }
        try await mutate(["stash", "apply", "--index", ref])
    }
}
