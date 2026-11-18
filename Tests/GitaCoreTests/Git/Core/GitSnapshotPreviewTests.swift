import Foundation
import Testing

@testable import GitaCore

/// The history a snapshot hands over before its working-tree status is read.
struct SnapshotPreviewTests {
    private actor Previews {
        var all: [RepositorySnapshot] = []
        func add(_ snapshot: RepositorySnapshot) { all.append(snapshot) }
    }

    /// Real Git, with `git status` held back so the history is always read first.
    private struct SlowStatusRunner: CommandRunning {
        let real = CommandRunner()

        func run(
            executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
        ) async throws -> CommandResult {
            try await real.run(
                executable: executable, arguments: arguments, directory: directory, timeout: timeout,
                outputLimit: outputLimit)
        }

        func run(_ request: CommandRequest) async throws -> CommandResult {
            if request.arguments.contains("status") { try await Task.sleep(for: .milliseconds(400)) }
            return try await real.run(request)
        }
    }

    @Test func previewCarriesTheHistoryAheadOfTheStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        func git(_ arguments: [String]) async throws {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["commit", "--allow-empty", "-m", "one"])
        try await git(["commit", "--allow-empty", "-m", "two"])
        try Data("x\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let previews = Previews()
        let service = GitService(root: root, runner: SlowStatusRunner())
        let snapshot = try await service.snapshot(limit: 10) { await previews.add($0) }
        #expect(!snapshot.isPreview)
        #expect(snapshot.changes.map(\.path) == ["untracked.txt"])
        let shown = await previews.all
        #expect(shown.count == 1)
        for preview in shown {
            #expect(preview.isPreview)
            #expect(preview.changes.isEmpty)
            #expect(preview.commits == snapshot.commits)
            #expect(preview.head == snapshot.head)
            #expect(preview.branch == "main")
            #expect(preview.references == snapshot.references)
        }
        // Without a callback nothing is handed over early.
        #expect(try await service.snapshot(limit: 10).commits.map(\.subject) == ["two", "one"])
    }
}
