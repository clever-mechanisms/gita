import Foundation
import Testing

@testable import GitaCore

/// A slow status refreshes the index's stat data: not while another Git holds the index, at most once a minute, and
/// without changing what is staged.
struct IndexRefreshTests {
    @Test func slowStatusRefreshesTheIndexOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaIndex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try Data("one\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await git(["add", "a.txt"])
        try await git(["commit", "-m", "one"])
        try Data("two\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await git(["add", "a.txt"])
        let staged = try await git(["diff", "--cached"])

        let service = GitService(root: root)
        _ = try await service.snapshot(limit: 10)
        #expect(await !service.indexRefreshWouldHelp())
        await service.noteStatus(.seconds(1))
        #expect(await service.indexRefreshWouldHelp())

        // Another Git holds the index: leave it alone.
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        #expect(await !service.indexRefreshWouldHelp())
        try FileManager.default.removeItem(at: lock)

        try await service.refreshIndex()
        #expect(try await git(["diff", "--cached"]) == staged)
        // Status got fast: refreshing helped and may run again after the interval.
        await service.noteStatus(.milliseconds(100))
        await service.noteStatus(.seconds(1))
        #expect(await !service.indexRefreshWouldHelp())
        #expect(await service.indexRefreshWouldHelp(now: .now + .seconds(61)))
        // A refresh after which status is as slow as before did not help: the index is left alone from then on.
        try await service.refreshIndex()
        await service.noteStatus(.milliseconds(900))
        #expect(await !service.indexRefreshWouldHelp(now: .now + .seconds(61)))
    }

    /// A status read that started before the refresh ended still saw the old stat data: it does not judge the
    /// refresh. The first read started after it does.
    @Test func onlyAStatusStartedAfterTheRefreshJudgesIt() async throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = GitService(root: root)
        _ = try await service.snapshot(limit: 10)
        await service.noteStatus(.seconds(1))
        let startedBefore = ContinuousClock.now
        try await service.refreshIndex()
        await service.noteStatus(.seconds(1), startedAt: startedBefore)
        #expect(await service.indexRefreshTrial != .useless)
        await service.noteStatus(.milliseconds(100))
        #expect(await service.indexRefreshTrial == .allowed)
    }

    /// A refresh that fails before Git runs leaves nothing to judge: the next slow status does not count against it.
    @Test func aFailedRefreshLeavesTheVerdictAsItWas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitaIndex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = GitService(root: folder)
        await service.noteStatus(.seconds(1))
        await #expect(throws: (any Error).self) { try await service.refreshIndex() }
        #expect(await service.indexRefreshTrial == .allowed)
        await service.noteStatus(.seconds(1))
        #expect(await service.indexRefreshTrial == .allowed)
    }

    /// A repository with one commit, made with the system Git.
    private static func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaIndex-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        for arguments in [
            ["init", "-q", "--initial-branch=main", "--template="], ["add", "a.txt"], ["commit", "-q", "-m", "one"],
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments =
                ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = root
            try process.run()
            process.waitUntilExit()
        }
        return root
    }
}
