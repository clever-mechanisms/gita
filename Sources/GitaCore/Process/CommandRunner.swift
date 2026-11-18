import Foundation

/// Small, short-lived POSIX children, without Foundation Process/Pipe lifetime hazards.
/// Both streams drain concurrently. Cancellation and deadlines also end descendants.
///
/// Each child is watched by a thread of its own, never by a Swift concurrency worker: a fetch or clone can block
/// for minutes, and the cooperative pool is only about as wide as the CPU.
public struct CommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String, arguments: [String], directory: URL? = nil,
        timeout: TimeInterval = CommandRequest.defaultTimeout, outputLimit: Int = CommandRequest.defaultOutputLimit
    ) async throws -> CommandResult {
        try await run(
            CommandRequest(
                executable: executable, arguments: arguments, directory: directory, timeout: timeout,
                outputLimit: outputLimit))
    }

    public func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.isValid else { throw CommandError.invalidArgument }
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                Thread {
                    continuation.resume(with: Result { try Self.execute(request, cancellation: cancellation) })
                }.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Starts `request`'s program with the environment its policy gives it.
    static func spawn(_ request: CommandRequest) throws -> ChildProcess {
        let inherited = ProcessInfo.processInfo.environment
        let path = try ChildEnvironment.resolve(
            request.executable,
            searchPaths: ChildEnvironment.searchPaths(policy: request.environment, inherited: inherited))
        let environment = ChildEnvironment.make(
            policy: request.environment, editors: request.editors, inherited: inherited)
        return try ChildProcess.spawn(path: path, request: request, environment: environment)
    }

    private static func execute(_ request: CommandRequest, cancellation: CancellationFlag) throws -> CommandResult {
        if cancellation.isCancelled { throw CancellationError() }
        let child = try spawn(request)
        var pump = OutputPump(limit: request.outputLimit)
        do {
            try pump.drain(
                child, timeLimit: OutputPump.TimeLimit(request: request, start: ProcessInfo.processInfo.systemUptime),
                cancellation: cancellation)
        } catch {
            child.terminate()
            throw error
        }
        child.reap()
        guard let exitCode = child.exitCode else { throw CommandError.ioFailed(ECHILD) }
        return CommandResult(stdout: pump.stdout, stderr: pump.stderr, exitCode: exitCode)
    }
}
