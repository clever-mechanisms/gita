import Foundation

/// The light per-repository facts the Repositories sidebar and the menu bar panel show, read with two cheap Git calls.
public struct WorkspaceGitStatus: Sendable, Hashable {
    public var branch: String?
    public var ahead = 0, behind = 0
    public var changedFiles = 0
    public var worktrees: [GitWorktree] = []
    public init() {}
}

public enum WorkspaceStatusReader {
    /// `git status --porcelain=v2 --branch` → branch (nil when detached), ahead/behind, changed entries incl.
    /// untracked.
    public static func parseStatus(_ data: Data) -> WorkspaceGitStatus {
        var status = WorkspaceGitStatus()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { status.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { status.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") || line.hasPrefix("? ") {
                status.changedFiles += 1
            }
        }
        return status
    }

    /// Linked worktrees only: the main checkout (`root`, always listed first) and bare entries are excluded.
    public static func linkedWorktrees(_ data: Data, root: URL) -> [GitWorktree] {
        // Same normalisation as `AgentCheckout` paths, so a worktree row and its agent session compare equal.
        let main = root.standardizedFileURL.path
        return GitParsers.worktrees(data).dropFirst().compactMap { tree in
            var tree = tree
            tree.path = URL(fileURLWithPath: tree.path, isDirectory: true).standardizedFileURL.path
            return tree.isBare || tree.path == main ? nil : tree
        }
    }

    /// Reads both with `--no-optional-locks`, so watching `.git` never sees its own index refresh, and without a
    /// repository-supplied fsmonitor hook, which `status` would otherwise run.
    public static func read(root: URL, runner: any CommandRunning = CommandRunner()) async throws -> WorkspaceGitStatus
    {
        let hardening = await FSMonitorHardening.shared.readOptions(root: root, runner: runner)
        async let statusResult = runner.run(
            CommandRequest.git(
                ["--no-optional-locks"] + hardening + ["status", "--porcelain=v2", "--branch"], directory: root,
                timeout: 20, outputLimit: 8 * 1_024 * 1_024))
        async let worktreeResult = runner.run(
            CommandRequest.git(
                ["--no-optional-locks", "worktree", "list", "--porcelain", "-z"], directory: root, timeout: 10,
                outputLimit: 1_024 * 1_024))
        let (statusOutput, worktreeOutput) = try await (statusResult, worktreeResult)
        guard statusOutput.exitCode == 0 else { throw WorkspaceStatusError.notRepository }
        var status = parseStatus(statusOutput.stdout)
        if worktreeOutput.exitCode == 0 { status.worktrees = linkedWorktrees(worktreeOutput.stdout, root: root) }
        return status
    }
}

public enum WorkspaceStatusError: Error, Sendable { case notRepository }
