import Foundation

@testable import GitaCore

struct StorageFixture {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { container.appendingPathComponent("repo") }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func initialize() async throws {
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Storage Tests"])
        try await git(["config", "user.email", "storage@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", "/dev/null"])
        try await git(["commit", "--allow-empty", "-m", "Initial commit"])
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> CommandResult {
        try await StorageGit(runner: CommandRunner()).read(arguments, at: root)
    }

    @discardableResult
    func write(_ path: String, _ data: Data = Data(repeating: 42, count: 8_192)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: container) }

    func ignoredEntry() async throws -> HeavyFolderEntry {
        try write(".gitignore", Data("node_modules/\n".utf8))
        try write("node_modules/item")
        let report = try await StorageScanner().scan(repositoryRoot: root)
        guard let entry = report.checkouts.first?.heavyFolders.first else { throw GitError.invalidPath }
        return entry
    }
}
