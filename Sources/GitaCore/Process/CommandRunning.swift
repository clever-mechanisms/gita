import Foundation

/// Runs child processes. Conformers implement the argv form; `run(_:)` is what Gita calls, and its default
/// forwards a request without editor overrides. A runner that cannot apply editor overrides must refuse them: a
/// native interactive rebase may never fall back to Git's default editor.
public protocol CommandRunning: Sendable {
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult
    func run(_ request: CommandRequest) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.editors == nil else { throw CommandError.invalidArgument }
        return try await run(
            executable: request.executable, arguments: request.arguments, directory: request.directory,
            timeout: request.timeout, outputLimit: request.outputLimit)
    }
}
