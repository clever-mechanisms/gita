import Foundation

extension AgentArenaService {
    // A nil command skips the optional build check.
    public func runContestant(
        _ workspace: ArenaWorkspace, config: ArenaAgentConfig, prompt: String, baseCommit: String,
        // swiftlint:disable:next discouraged_optional_collection
        checkCommand: [String]?, timeout: TimeInterval = 300
    ) async throws -> ArenaContestantOutcome {
        let root = workspace.worktreePath
        let git = AgentControlGit(root: root, runner: runner)
        guard let base = try await git.resolve(baseCommit) else { throw GitError.invalidReference }
        let args = config.resolvedArguments(prompt: prompt)
        guard !args.isEmpty else { throw CommandError.invalidArgument }
        if let checkCommand { try validate(checkCommand) }
        let agent = try await execute([config.executable] + args, root: root, timeout: timeout)
        let check: ArenaBuildCheckResult?
        if let checkCommand {
            check = try await execute(checkCommand, root: root, timeout: timeout)
        } else {
            check = nil
        }
        let tree = try await git.worktreeTree()
        let patch = try await git.fullDiff(from: base, to: tree)
        return ArenaContestantOutcome(
            contestant: workspace.id, config: config, worktreePath: root,
            branchName: workspace.branchName, agentExitCode: agent.exitCode, agentOutputExcerpt: agent.outputExcerpt,
            diffFromBase: patch, changedFiles: try await git.files(from: base, to: tree),
            durationSeconds: agent.durationSeconds, checkResult: check)
    }

    private func validate(_ command: [String]) throws {
        guard let program = command.first, !program.isEmpty, !command.contains(where: { $0.utf8.contains(0) }) else {
            throw CommandError.invalidArgument
        }
        let name = URL(fileURLWithPath: program).lastPathComponent
        if ["sh", "bash", "zsh", "ksh", "csh", "tcsh", "fish", "dash"].contains(name) {
            throw CommandError.invalidArgument
        }
    }

    private func execute(_ command: [String], root: URL, timeout: TimeInterval) async throws -> ArenaBuildCheckResult {
        try validate(command)
        guard let executable = command.first else { throw CommandError.invalidArgument }
        let request = CommandRequest(
            executable: executable, arguments: Array(command.dropFirst()), directory: root, timeout: timeout)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await runner.run(request)
        let limit = 64 * 1_024
        var output = Data(result.stdout.prefix(limit))
        output.append(result.stderr.prefix(limit - output.count))
        return ArenaBuildCheckResult(
            command: command, exitCode: result.exitCode,
            outputExcerpt: AgentControlGit.excerpt(output, limit: limit).text,
            durationSeconds: ProcessInfo.processInfo.systemUptime - start)
    }
}
