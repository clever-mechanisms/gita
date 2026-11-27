import Foundation

struct StorageGit: Sendable {
    let runner: any CommandRunning
    var globalConfigURL: URL?

    func read(_ arguments: [String], at root: URL?, allowingMissing: Bool = false) async throws -> CommandResult {
        try Task.checkCancellation()
        var request = CommandRequest.git(arguments, directory: root)
        applyGlobalConfig(to: &request)
        let result = try await runner.run(request)
        if allowingMissing && result.exitCode == 1 { return result }
        return try Self.checked(result)
    }

    func applyGlobalConfig(to request: inout CommandRequest) {
        guard let globalConfigURL else { return }
        request.environment.added["GIT_CONFIG_GLOBAL"] = globalConfigURL.path
        request.environment.added["GIT_CONFIG_NOSYSTEM"] = "1"
    }

    static func checked(_ result: CommandResult) throws -> CommandResult {
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }

    func commonDirectory(at root: URL) async throws -> URL {
        let result = try await read(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
        let path = GitOutput.withoutTerminalLF(result.text)
        guard path.hasPrefix("/") else { throw GitError.notRepository }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    func worktrees(at root: URL) async throws -> [GitWorktree] {
        let result = try await read(["worktree", "list", "--porcelain", "-z"], at: root)
        let trees = GitParsers.worktrees(result.stdout)
        guard !trees.isEmpty else { throw GitError.notRepository }
        return trees
    }
}
