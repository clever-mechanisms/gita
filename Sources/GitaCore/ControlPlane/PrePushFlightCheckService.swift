import Foundation

public actor PrePushFlightCheckService {
    public typealias Update = @Sendable (FlightCheckState) async -> Void
    public struct Completion: Sendable {
        public let state: FlightCheckState
        public let cached: Bool
    }

    private struct Key: Hashable {
        let root: String
        let sha: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(root)
            hasher.combine(sha)
        }
    }
    private struct Run {
        let id: UUID
        let task: Task<Completion, Never>
    }
    private var runs: [String: Run] = [:]
    private var cache: [Key: FlightCheckResult] = [:]
    private var recency: [Key] = []
    public init() {}

    @discardableResult
    public func run(
        gitService git: GitService, command: FlightCheckCommand, force: Bool = false,
        update: @escaping Update = { _ in }
    ) async -> Completion {
        let root = git.root.standardizedFileURL.resolvingSymlinksInPath().path
        let previous = runs[root]
        previous?.task.cancel()
        let id = UUID()
        let task = Task {
            _ = await previous?.task.value
            let result = await perform(git: git, root: root, command: command, force: force, update: update)
            await update(result.state)
            return result
        }
        runs[root] = Run(id: id, task: task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if runs[root]?.id == id { runs[root] = nil }
        return result
    }

    private func perform(
        git: GitService, root: String, command: FlightCheckCommand, force: Bool,
        update: @escaping Update
    ) async -> Completion {
        do {
            try Task.checkCancellation()
            try command.validate()
            let sha = GitOutput.withoutTerminalLF(try await git.execute(["rev-parse", "--verify", "HEAD"]).text)
            guard GitParsers.isObjectID(sha) else { throw GitError.invalidReference }
            let key = Key(root: root, sha: sha)
            if !force, let hit = cache[key], hit.command == command {
                touch(key)
                return Completion(state: hit.succeeded ? .passed(hit) : .failed(hit), cached: true)
            }
            await update(.preparing(commitSHA: sha))
            let result = try await Self.check(git: git, sha: sha, command: command, update: update)
            try Task.checkCancellation()
            cache[key] = result
            touch(key)
            return Completion(state: result.succeeded ? .passed(result) : .failed(result), cached: false)
        } catch is CancellationError {
            return Completion(state: .cancelled, cached: false)
        } catch {
            return Completion(state: .error(message: error.localizedDescription), cached: false)
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
        if recency.count > 32 { cache[recency.removeFirst()] = nil }
    }

    private static func check(
        git: GitService, sha: String, command: FlightCheckCommand,
        update: @escaping Update
    ) async throws -> FlightCheckResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitaFlightCheck-\(UUID())")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let result: Result<FlightCheckResult, Error>
        do {
            _ = try await git.execute(
                GitArguments.noHooks + ["worktree", "add", "--detach", "--", folder.path, sha], mutation: true)
            let startUptime = ProcessInfo.processInfo.systemUptime
            let started = Date()
            await update(.running(commitSHA: sha, startedAt: started, tail: FlightCheckOutput()))
            let (code, tail) = try await FlightCheckProcess.run(command: command, at: folder) { output in
                await update(.running(commitSHA: sha, startedAt: started, tail: output))
            }
            result = .success(
                FlightCheckResult(
                    commitSHA: sha, command: command, succeeded: code == 0,
                    exitCode: code, duration: ProcessInfo.processInfo.systemUptime - startUptime, output: tail))
        } catch {
            result = .failure(error)
        }
        try await Task.detached(priority: .utility) { try await cleanUp(folder, git: git) }.value
        return try result.get()
    }

    private static func cleanUp(_ folder: URL, git: GitService) async throws {
        // A check can lock its own worktree. The second force flag covers that case.
        _ = try? await git.execute(["worktree", "remove", "--force", "--force", "--", folder.path], mutation: true)
        let remainder = Result {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        }
        _ = try await git.execute(["worktree", "prune"], mutation: true)
        try remainder.get()
    }
}
