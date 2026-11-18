import Foundation
import Testing

@testable import GitaCore

/// A repository whose `core.fsmonitor` names a hook that leaves a marker file: the reads the app starts on its own
/// must never run it. Mutates only a temporary repository.
@Suite struct GitFSMonitorHookTests {
    private struct Fixture {
        let root: URL
        let marker: URL
        var hookRan: Bool { FileManager.default.fileExists(atPath: marker.path) }
    }

    private func fixture() async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaFSMonitor-" + UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = base.appendingPathComponent("hook-ran")
        let hook = base.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let runner = CommandRunner()
        try "x\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "ignored/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for arguments in [
            ["init", "--initial-branch=main"], ["config", "user.email", "t@example.invalid"],
            ["config", "user.name", "T"], ["add", "."], ["commit", "-m", "init"],
            ["config", "core.fsmonitor", hook.path],
        ] {
            let result = try await runner.run(
                executable: "git", arguments: arguments, directory: root, timeout: 10, outputLimit: 65_536)
            try #require(result.exitCode == 0)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ignored/deep"), withIntermediateDirectories: true)
        return Fixture(root: root, marker: marker)
    }

    @Test func workspaceStatusDoesNotRunTheHook() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let status = try await WorkspaceStatusReader.read(root: fixture.root)
        #expect(status.branch == "main")
        #expect(!fixture.hookRan)
    }

    @Test func eventFilterDoesNotRunTheHook() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let filter = WorktreeEventFilter(root: fixture.root)
        let root = fixture.root.standardizedFileURL.path
        #expect(await filter.isRelevant([root + "/ignored/deep/file.o"]) == false)
        #expect(await filter.isRelevant([root + "/tracked.txt"]) == true)
        #expect(!fixture.hookRan)
    }

    @Test func aBooleanSettingKeepsTheBuiltInMonitor() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        _ = try await CommandRunner().run(
            executable: "git", arguments: ["config", "core.fsmonitor", "false"], directory: fixture.root,
            timeout: 10, outputLimit: 65_536)
        let options = await FSMonitorHardening.shared.readOptions(root: fixture.root, runner: CommandRunner())
        #expect(options.isEmpty)
    }
}
