import Foundation

struct StorageGit: Sendable {
    let runner: any CommandRunning

    func read(_ arguments: [String], at root: URL, allowingMissing: Bool = false) async throws -> CommandResult {
        try Task.checkCancellation()
        let result = try await runner.run(.git(arguments, directory: root))
        if allowingMissing && result.exitCode == 1 { return result }
        return try Self.checked(result)
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
