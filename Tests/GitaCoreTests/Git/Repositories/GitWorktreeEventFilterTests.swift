import Foundation
import Testing

@testable import GitaCore

/// Mutates only a temporary repository.
struct WorktreeEventFilterTests {
    private func repository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaFilter-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = CommandRunner()
        for args in [
            ["init", "--initial-branch=main"], ["config", "user.email", "t@example.invalid"],
            ["config", "user.name", "T"],
        ] {
            _ = try await runner.run(
                executable: "git", arguments: args, directory: root, timeout: 10, outputLimit: 65_536)
        }
        try ".build/\nnode_modules/\n*.log\nvendor/\n".write(
            to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for directory in [".build/debug/obj", "node_modules/a/b", "src", "vendor"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("vendor/kept.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        _ = try await runner.run(
            executable: "git", arguments: ["add", "-f", "vendor/kept.txt", "src/main.swift", ".gitignore"],
            directory: root, timeout: 10, outputLimit: 65_536)
        _ = try await runner.run(
            executable: "git", arguments: ["commit", "-m", "init"], directory: root, timeout: 10, outputLimit: 65_536)
        return root
    }

    @Test func ignoredTreesAreDroppedAndEverythingElseCounts() async throws {
        let root = try await repository()
        defer { try? FileManager.default.removeItem(at: root) }
        // FSEvents spells temporary paths `/private/var/…`, which Foundation's resolver would strip.
        let real =
            realpath(root.path, nil).map { path in
                defer { free(path) }
                return String(cString: path)
            } ?? root.path
        #expect(real.hasPrefix("/private/"))
        let filter = WorktreeEventFilter(root: root)
        #expect(
            await filter.isRelevant([
                real + "/.build/debug/obj/a.o", real + "/node_modules/a/b/index.js", real + "/server.log",
            ]) == false)
        #expect(await filter.isRelevant([root.path + "/.build/debug/obj/b.o"]) == false) // unresolved spelling
        #expect(await filter.isRelevant([real + "/.build/debug/obj/a.o", real + "/src/main.swift"]) == true)
        #expect(await filter.isRelevant([real + "/vendor/kept.txt"]) == true) // ignored dir with tracked file
        #expect(await filter.isRelevant([real + "/.git/index"]) == true)
        #expect(await filter.isRelevant([real]) == true)
        #expect(await filter.isRelevant([real + "/.gitignore"]) == true)
        #expect(await filter.isRelevant(["/somewhere/else"]) == true)
    }
}
