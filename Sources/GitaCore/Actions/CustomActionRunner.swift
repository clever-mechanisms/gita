import Foundation

public struct CustomActionRunner: Sendable {
    private let runner: any CommandRunning
    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    public func resolve(_ action: CustomAction, context: CustomActionContext) throws -> ResolvedCustomActionCommand {
        try CustomActionStore.validate(action)
        let root = URL(fileURLWithPath: context.repositoryRoot.path, isDirectory: true)
        func expand(_ token: String) throws -> String {
            try CommandTemplate.expand(token) { key in
                try Self.value(for: key, context: context, root: root)
            }
        }
        let arguments = try action.arguments.map(expand)
        try CommandTemplate.validate(executable: action.executable, arguments: arguments)
        let directory =
            try action.workingDirectory.map {
                URL(fileURLWithPath: try expand($0), isDirectory: true, relativeTo: root).standardizedFileURL
            } ?? context.repositoryRoot
        return ResolvedCustomActionCommand(executable: action.executable, arguments: arguments, directory: directory)
    }

    public func run(_ action: CustomAction, context: CustomActionContext) async throws -> CustomActionRunOutput {
        let command = try resolve(action, context: context)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await runner.run(
                CommandRequest(
                    executable: command.executable, arguments: command.arguments, directory: command.directory,
                    timeout: action.timeoutSeconds, outputLimit: CommandRequest.defaultOutputLimit))
            return CustomActionRunOutput(
                command: command, stdout: result.text,
                stderr: String(decoding: result.stderr, as: UTF8.self),
                exitCode: result.exitCode, duration: ProcessInfo.processInfo.systemUptime - start)
        } catch is CancellationError { throw CancellationError() } catch {
            throw CustomActionError.execution(error.localizedDescription)
        }
    }

    private static func value(for key: String, context: CustomActionContext, root: URL) throws -> String? {
        switch key {
        case "$REPO_ROOT":
            return try nonNull(context.repositoryRoot.path, key: key)
        case "$WORKTREE":
            return try nonNull(context.worktreePath?.path, key: key)
        case "$SHA":
            let value = try nonNull(context.commitSHA, key: key)
            return try validateRef(value)
        case "$BRANCH":
            let value = try nonNull(context.branch, key: key)
            return try validateRef(value)
        case "$FILE":
            let raw = try nonNull(context.filePath, key: key)
            return try resolveFilePath(raw, root: root)
        case "$REMOTE_URL":
            return try nonNull(context.remoteURL, key: key)
        default:
            return nil
        }
    }

    private static func nonNull(_ value: String?, key: String) throws -> String {
        guard let value, !value.isEmpty else { throw CustomActionError.missingPlaceholder(key) }
        guard !value.contains("\0") else { throw CustomActionError.invalidArgument }
        return value
    }

    private static func validateRef(_ ref: String) throws -> String {
        do {
            try GitInput.validateReference(ref)
            return ref
        } catch { throw CustomActionError.invalidArgument }
    }

    /// Resolves `$FILE` to an absolute path under the repository root so leading dashes cannot act as CLI options
    /// and paths remain valid when workingDirectory differs from repositoryRoot.
    private static func resolveFilePath(_ raw: String, root: URL) throws -> String {
        do { try GitInput.validatePath(raw) } catch { throw CustomActionError.invalidArgument }
        return URL(fileURLWithPath: raw, relativeTo: root).standardizedFileURL.path
    }
}
