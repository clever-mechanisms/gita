import Foundation
import Testing

@testable import GitaCore

/// Reset File to State at / Before Commit, Discard Changes and Save As on a temporary repository.
@Suite(.serialized)
struct FileRestoreTests {
    private func repository() async throws -> (root: URL, service: GitService, git: ([String]) async throws -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaRestore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = CommandRunner()
        let git: ([String]) async throws -> Void = { arguments in
            let result = try await runner.run(
                executable: "git", arguments: arguments, directory: root, timeout: 10, outputLimit: 1_024 * 1_024)
            guard result.exitCode == 0 else {
                throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
            }
        }
        for arguments in [
            ["init", "--initial-branch=main"], ["config", "user.name", "Gita Tests"],
            ["config", "user.email", "tests@example.invalid"],
            ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", "/dev/null"],
        ] { try await git(arguments) }
        return (root, GitService(root: root), git)
    }
    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func resetFileToStateAtAndBeforeCommit() async throws {
        let (root, service, _) = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "one\n")
        try await service.stage(paths: ["a.txt"])
        try await service.commit(message: "first")
        try write(root, "a.txt", "two\n")
        try write(root, "dir/new.txt", "new\n")
        try await service.stage(paths: ["a.txt", "dir/new.txt"])
        try await service.commit(message: "second")
        let second = try await service.snapshot().head!
        try write(root, "a.txt", "three\n")
        try await service.stage(paths: ["a.txt"])
        try await service.commit(message: "third")

        try await service.restore(paths: ["a.txt"], from: second)
        #expect(read(root, "a.txt") == "two\n")
        #expect(try await service.snapshot().changes.first { $0.path == "a.txt" }?.isStaged == true)

        // Before the second commit: a.txt was "one" and dir/new.txt did not exist.
        try await service.restore(paths: ["a.txt", "dir/new.txt"], from: second + "^")
        #expect(read(root, "a.txt") == "one\n")
        #expect(read(root, "dir/new.txt") == nil)
        #expect(try await service.fileData(commit: second, path: "dir/new.txt") == Data("new\n".utf8))
        await #expect(throws: GitError.self) { try await service.restore(paths: ["../outside"], from: second) }
    }

    @Test func discardRestoresTrackedFilesAndDeletesUntrackedOnes() async throws {
        let (root, service, _) = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "kept.txt", "kept\n")
        try await service.stage(paths: ["kept.txt"])
        try await service.commit(message: "first")
        try write(root, "kept.txt", "staged\n")
        try await service.stage(paths: ["kept.txt"])
        try write(root, "kept.txt", "unstaged\n")
        try write(root, "folder/scratch.txt", "scratch\n")
        try write(root, "other.txt", "other\n")
        try await service.discard(paths: ["kept.txt", "folder/scratch.txt"])
        // The staged content stays; only the working-tree edit goes.
        #expect(read(root, "kept.txt") == "staged\n")
        #expect(read(root, "folder/scratch.txt") == nil)
        #expect(read(root, "other.txt") == "other\n")
    }
}
