import Foundation
import Testing

@testable import GitaCore

struct AgentControlFixture: Sendable {
    let container: URL
    let root: URL

    static func withRepository(_ body: (Self) async throws -> Void) async throws {
        let container = try PrivateTemporaryDirectory.make(
            prefix: "GitaAgentControlTests", failure: LocalFileError.destinationNotCreated)
        defer { try? FileManager.default.removeItem(at: container) }
        let fixture = Self(container: container, root: container.appending(path: "repo"))
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try await fixture.git(["init", "--initial-branch=main", "--template="])
        try await fixture.git(["config", "user.name", "Gita Tests"])
        try await fixture.git(["config", "user.email", "gita@example.invalid"])
        try await fixture.git(["config", "commit.gpgsign", "false"])
        try await fixture.git(["config", "core.hooksPath", "/dev/null"])
        try await body(fixture)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await CommandRunner().run(CommandRequest.git(arguments, directory: directory ?? root))
        guard result.exitCode == 0 else { throw GitService.failure(result) }
        return GitOutput.withoutTerminalLF(result.text)
    }

    func write(_ path: String, _ contents: String, in directory: URL? = nil) throws {
        try Data(contents.utf8).write(to: (directory ?? root).appendingPathComponent(path))
    }

    func read(_ path: String, in directory: URL? = nil) throws -> String {
        try String(contentsOf: (directory ?? root).appendingPathComponent(path), encoding: .utf8)
    }

    func commit(in directory: URL? = nil) async throws {
        try await git(["add", "-A"], in: directory)
        try await git(["commit", "-m", "Fixture"], in: directory)
    }

    func sibling() async throws -> URL {
        let path = container.appending(path: "sibling")
        try await git(["worktree", "add", "-b", "other", "--", path.path, "HEAD"])
        return path
    }

    func lines(_ edits: [Int: String] = [:]) -> String {
        (1...64).map { edits[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func index(in directory: URL? = nil) async throws -> Data {
        let path = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: directory)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
