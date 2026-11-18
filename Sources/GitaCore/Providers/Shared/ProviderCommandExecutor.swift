import Foundation

/// Runs one provider CLI command with a deadline and an output cap, and turns every failure into a
/// `ProviderFailure`. Authentication stays with each CLI: nothing here reads credentials or changes login state.
struct ProviderCommandExecutor: Sendable {
    struct Limits: Sendable {
        var timeout: TimeInterval
        var outputLimit: Int

        /// Refreshes and detail reads.
        static let read = Self(timeout: 20, outputLimit: 2 * 1_024 * 1_024)
        /// User-confirmed deployment changes.
        static let action = Self(timeout: 90, outputLimit: 512 * 1_024)
        /// The review window's conversation and diff, which carry bodies and whole patches.
        static let review = Self(timeout: 30, outputLimit: 16 * 1_024 * 1_024)
    }

    let runner: any CommandRunning

    /// The finished command, whatever its exit status.
    func run(
        _ tool: ProviderTool, _ arguments: [String], in root: URL, limits: Limits = .read
    ) async -> Result<CommandResult, ProviderFailure> {
        await run(ProviderCommand(tool, arguments), in: root, limits: limits)
    }

    /// The finished command, whatever its exit status. A `gita-gh` command whose account is signed out, or that
    /// finds no `gh`, fails here with that reason.
    func run(
        _ command: ProviderCommand, in root: URL, limits: Limits = .read
    ) async -> Result<CommandResult, ProviderFailure> {
        let tool = command.tool
        do {
            try Task.checkCancellation()
            var request = CommandRequest(
                executable: command.executable, arguments: command.arguments, directory: root,
                timeout: limits.timeout, outputLimit: limits.outputLimit)
            request.environment = command.environment
            let result = try await runner.run(request)
            try Task.checkCancellation()
            if let account = command.account {
                if result.exitCode == GitHubAccountCommand.signedOutExit { return .failure(.signedOut(account)) }
                if result.exitCode == GitHubAccountCommand.notInstalledExit { return .failure(.notInstalled(tool)) }
            }
            return .success(result)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as CommandError {
            return .failure(Self.failure(error, tool: tool))
        } catch {
            return .failure(ProviderFailureClassifier.classify(error.localizedDescription, tool: tool, exitCode: nil))
        }
    }

    /// Standard output of a command that exited 0.
    func execute(_ tool: ProviderTool, _ arguments: [String], in root: URL) async -> Result<Data, ProviderFailure> {
        await execute(ProviderCommand(tool, arguments), in: root)
    }

    /// Standard output of a command that exited 0.
    func execute(_ command: ProviderCommand, in root: URL) async -> Result<Data, ProviderFailure> {
        switch await run(command, in: root) {
        case .failure(let failure): .failure(failure)
        case .success(let result) where result.exitCode == 0: .success(result.stdout)
        case .success(let result): .failure(Self.commandFailure(result, tool: command.tool))
        }
    }

    static func commandFailure(_ result: CommandResult, tool: ProviderTool) -> ProviderFailure {
        ProviderFailureClassifier.classify(
            LossyText.decode(result.stderr) + result.text, tool: tool, exitCode: result.exitCode)
    }

    /// A failure whose standard output was a structured response already examined: only standard error is
    /// classified, so field names in the response (such as `login`) are never read as an error message.
    static func stderrFailure(_ result: CommandResult, tool: ProviderTool) -> ProviderFailure {
        ProviderFailureClassifier.classify(LossyText.decode(result.stderr), tool: tool, exitCode: result.exitCode)
    }

    private static func failure(_ error: CommandError, tool: ProviderTool) -> ProviderFailure {
        switch error {
        case .executableNotFound: .notInstalled(tool)
        case .timedOut: .timedOut(tool)
        case .outputLimitExceeded: .tooLarge(tool)
        default: .incomplete(tool)
        }
    }
}
