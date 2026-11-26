import Darwin
import Foundation

public actor AgentArenaService {
    let runner: any CommandRunning
    private var owned: [URL: (gate: GitService, workspace: ArenaWorkspace)] = [:]

    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    public func createWorktrees(
        in repositoryRoot: URL, baseCommit: String, runID: String = UUID().uuidString,
        onPrepare: @Sendable ([ArenaWorkspace]) async -> Void = { _ in }
    )
        async throws -> (alpha: ArenaWorkspace, beta: ArenaWorkspace)
    {
        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let git = AgentControlGit(root: root, runner: runner)
        guard let base = try await git.resolve(baseCommit) else { throw GitError.invalidReference }
        let parent = try PrivateTemporaryDirectory.make(
            prefix: "GitaArena", failure: LocalFileError.destinationNotCreated)
        let shortID = Data(runID.utf8).sha256Hex.prefix(12)
        let branch = "gita/arena-" + shortID
        let alpha = ArenaWorkspace(id: .alpha, worktreePath: parent.appending(path: "alpha"), branchName: branch + "-a")
        let beta = ArenaWorkspace(id: .beta, worktreePath: parent.appending(path: "beta"), branchName: branch + "-b")
        await onPrepare([alpha, beta])
        let gate = GitService(root: root, runner: runner)
        do {
            for workspace in [alpha, beta] {
                try Task.checkCancellation()
                // Finish branch reservation before observing cancellation, so rollback knows what we own.
                _ = try await Task { try await git.run(["branch", "--", workspace.branchName, base]) }.value
                owned[workspace.worktreePath] = (gate, workspace)
                try await git.run(["worktree", "add", "--", workspace.worktreePath.path, workspace.branchName])
            }
            try Task.checkCancellation()
            return (alpha, beta)
        } catch {
            await cleanup(in: root, workspaces: [alpha, beta])
            _ = rmdir(parent.path)
            throw error
        }
    }

    public func compare(
        in repositoryRoot: URL, runID: String, prompt: String, baseCommit: String,
        alpha: ArenaContestantOutcome, beta: ArenaContestantOutcome
    ) async throws -> ArenaComparison {
        _ = try validatePair(repositoryRoot, alpha: alpha, beta: beta)
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        async let a = AgentControlGit(root: alpha.worktreePath, runner: runner).worktreeTree()
        async let b = AgentControlGit(root: beta.worktreePath, runner: runner).worktreeTree()
        let diff = try await git.diff(from: a, to: b)
        return ArenaComparison(
            runID: runID, prompt: prompt, baseCommit: baseCommit, alpha: alpha, beta: beta,
            alphaVsBetaDiff: diff.text, isDiffTruncated: diff.truncated)
    }

    private func validatePair(
        _ root: URL, alpha: ArenaContestantOutcome, beta: ArenaContestantOutcome
    ) throws
        -> (ArenaWorkspace, ArenaWorkspace)
    {
        let repository = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let a = owned[alpha.worktreePath], let b = owned[beta.worktreePath],
            a.gate.root == repository, b.gate === a.gate, a.workspace.id == .alpha, b.workspace.id == .beta,
            a.workspace.branchName == alpha.branchName, b.workspace.branchName == beta.branchName
        else { throw GitError.invalidPath }
        return (a.workspace, b.workspace)
    }

    public func pickWinner(
        _ winner: ArenaContestantID, in repositoryRoot: URL, comparison: ArenaComparison
    )
        async throws -> (keptWorktree: URL, keptBranch: String)
    {
        guard let gate = owned[comparison.alpha.worktreePath]?.gate else { throw GitError.invalidPath }
        return try await gate.mutate { _ in
            let (alpha, beta) = try await self.validatePair(
                repositoryRoot, alpha: comparison.alpha, beta: comparison.beta)
            let (keep, discard) = winner == .alpha ? (alpha, beta) : (beta, alpha)
            // Complete both removal steps once a decision starts, even if its caller is cancelled.
            try await Task { try await self.remove(discard, from: repositoryRoot) }.value
            return (keep.worktreePath, keep.branchName)
        }
    }

    public func cleanup(in repositoryRoot: URL, workspaces: [ArenaWorkspace]) async {
        // Cleanup also runs from the cancellation path. Join it before returning to the caller.
        await Task {
            for workspace in workspaces {
                guard let gate = owned[workspace.worktreePath]?.gate else { continue }
                try? await gate.mutate { _ in try await self.remove(workspace, from: repositoryRoot) }
            }
        }.value
    }

    private func remove(_ workspace: ArenaWorkspace, from root: URL) async throws {
        let path = workspace.worktreePath
        guard let entry = owned[path], entry.workspace == workspace,
            entry.gate.root == root.standardizedFileURL.resolvingSymlinksInPath()
        else { return }
        let git = AgentControlGit(root: root, runner: runner)
        let listing = try await git.run(["worktree", "list", "--porcelain", "-z"])
        if GitParsers.worktrees(listing.stdout).contains(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == path.resolvingSymlinksInPath().path
        }) {
            try await git.run(["worktree", "remove", "--force", "--", path.path])
        }
        if try await git.resolve("refs/heads/" + workspace.branchName) != nil {
            try await git.run(["branch", "-D", "--", workspace.branchName])
        }
        owned[path] = nil
        _ = rmdir(path.deletingLastPathComponent().path)
    }
}
