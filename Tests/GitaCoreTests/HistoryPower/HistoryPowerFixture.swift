import Foundation

@testable import GitaCore

/// Disposable temporary Git repository fixture for HistoryPower core tests.
struct HistoryPowerFixture {
    let container: URL
    let root: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaHistoryPower-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["config", "user.name", "History Power Tests"])
        try await git(["config", "user.email", "history-power@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", "/dev/null"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    func write(_ path: String, _ contents: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: target)
    }

    @discardableResult
    func git(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git",
            arguments: arguments,
            directory: root,
            timeout: 20,
            outputLimit: 8 * 1_024 * 1_024
        )
        if !allowFailure && result.exitCode != 0 {
            throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }

    @discardableResult
    func commit(_ path: String, _ contents: String, message: String) async throws -> String {
        try write(path, contents)
        try await git(["add", "--", path])
        try await git(["commit", "-m", message])
        return try await head()
    }

    func head() async throws -> String {
        GitOutput.withoutTerminalLF(try await git(["rev-parse", "HEAD"]).text)
    }
}
