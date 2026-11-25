import Foundation
import Testing

@testable import GitaCore

@Suite("CommitEcosystem Submodules & Git LFS")
struct SubmodulesAndLFSTests {
    @Test func parseGitmodulesAndSubmoduleStatus() {
        let configPayload =
            [
                "submodule.libs/alpha.path\nlibs/alpha",
                "submodule.libs/alpha.url\nhttps://example.com/alpha.git",
                "submodule.libs/alpha.branch\nmain",
                "submodule.vendor/my lib.path\nvendor/my lib",
                "submodule.vendor/my lib.url\nhttps://example.com/mylib.git",
            ].joined(separator: "\0") + "\0"

        let metadata = GitService.parseGitmodulesConfig(Data(configPayload.utf8))
        #expect(metadata.count == 2)
        #expect(metadata["libs/alpha"]?.branch == "main")
        #expect(metadata["vendor/my lib"]?.url == "https://example.com/mylib.git")

        let sha1 = String(repeating: "a", count: 40)
        let sha2 = String(repeating: "b", count: 40)
        let sha3 = String(repeating: "c", count: 40)
        let sha4 = String(repeating: "d", count: 40)
        let statusOutput = """
             \(sha1) libs/alpha (v1.2.0)
            -\(sha2) vendor/my lib
            +\(sha3) packages/core (heads/main)
            U\(sha4) packages/conflicted
            """

        let parsed = GitService.parseSubmoduleStatus(statusOutput, metadata: metadata)
        #expect(parsed.count == 4)

        let alpha = parsed.first { $0.path == "libs/alpha" }
        #expect(alpha?.status == .clean)
        #expect(alpha?.url == "https://example.com/alpha.git")
        #expect(alpha?.branch == "main")
        #expect(alpha?.describe == "v1.2.0")
        #expect(alpha?.shortSHA == "aaaaaaa")

        let myLib = parsed.first { $0.path == "vendor/my lib" }
        #expect(myLib?.status == .uninitialized)
        #expect(myLib?.url == "https://example.com/mylib.git")

        #expect(parsed.first { $0.path == "packages/core" }?.status == .modified)
        #expect(parsed.first { $0.path == "packages/conflicted" }?.status == .conflict)
    }

    @Test func submoduleIntegrationInTemporaryRepo() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "root\n")
        try await fixture.commit("Root commit")

        let childRoot = fixture.container.appendingPathComponent("child-repo")
        try FileManager.default.createDirectory(at: childRoot, withIntermediateDirectories: true)
        let runner = CommandRunner()
        _ = try await runner.run(executable: "git", arguments: ["init", "-q", "-b", "main"], directory: childRoot)
        _ = try await runner.run(executable: "git", arguments: ["config", "user.name", "Tests"], directory: childRoot)
        _ = try await runner.run(
            executable: "git",
            arguments: ["config", "user.email", "tests@example.invalid"],
            directory: childRoot
        )
        _ = try await runner.run(
            executable: "git",
            arguments: ["config", "commit.gpgsign", "false"],
            directory: childRoot
        )
        try Data("child\n".utf8).write(to: childRoot.appendingPathComponent("child.txt"))
        _ = try await runner.run(executable: "git", arguments: ["add", "--all"], directory: childRoot)
        _ = try await runner.run(executable: "git", arguments: ["commit", "-q", "-m", "Child"], directory: childRoot)

        try await fixture.git([
            "-c", "protocol.file.allow=always",
            "submodule", "add", childRoot.path, "deps/child",
        ])
        try await fixture.commit("Add submodule")

        let submodules = try await fixture.service.submodules()
        #expect(submodules.count == 1)
        #expect(submodules[0].path == "deps/child")
        #expect(submodules[0].status == .clean)
        #expect(submodules[0].url == childRoot.path)

        try await fixture.service.syncSubmodules(path: "deps/child")
        try await fixture.service.updateSubmodules(path: "deps/child")
    }

    @Test func parseLFSPatternsStopsAtExcludedSectionAndParsesVerifiedLocks() throws {
        let trackOutput = """
            Listing tracked patterns
                *.psd (.gitattributes)
                assets/**/*.bin (.gitattributes)
            Listing excluded patterns
                *.bak (.gitattributes)
                tmp/*.psd (.gitattributes)
            """
        let patterns = GitService.parseTrackedPatterns(trackOutput)
        #expect(patterns.count == 2)
        #expect(patterns[0] == LFSPattern(pattern: "*.psd", source: ".gitattributes"))
        #expect(patterns[1] == LFSPattern(pattern: "assets/**/*.bin", source: ".gitattributes"))

        let oid1 = String(repeating: "1", count: 64)
        let oid2 = String(repeating: "2", count: 64)
        let lsOutput = """
            \(oid1) * assets/hero image.psd
            \(oid2) - models/weights.bin
            """
        let files = GitService.parseLFSFiles(lsOutput)
        #expect(files.count == 2)
        #expect(files[0].path == "assets/hero image.psd")
        #expect(files[0].isDownloaded)
        #expect(files[0].shortOID == String(repeating: "1", count: 10))
        #expect(files[1].path == "models/weights.bin")
        #expect(!files[1].isDownloaded)

        let verifiedJSON = Data(
            """
            {
              "ours": [{"id":"42","path":"assets/hero image.psd","owner":{"name":"Alice"}}],
              "theirs": [{"id":"43","path":"models/weights.bin","owner":{"name":"Bob"}}]
            }
            """.utf8
        )
        let verifiedLocks = try GitService.parseLFSLocksJSON(verifiedJSON)
        #expect(verifiedLocks.count == 2)
        #expect(verifiedLocks[0].path == "assets/hero image.psd")
        #expect(verifiedLocks[0].isOwnedByCurrentUser)
        #expect(verifiedLocks[1].path == "models/weights.bin")
        #expect(!verifiedLocks[1].isOwnedByCurrentUser)

        let textLocks = GitService.parseLFSLocksText("models/weights.bin\tBob\tID:99\n")
        #expect(textLocks == [LFSLockEntry(id: "99", path: "models/weights.bin", owner: "Bob", lockedAt: nil)])

        let tempCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaLFSCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempCache) }
        try FileManager.default.createDirectory(
            at: tempCache.appendingPathComponent("objects/ab"),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0xAA, count: 1_500).write(to: tempCache.appendingPathComponent("objects/ab/file1"))
        try Data(repeating: 0xBB, count: 500).write(to: tempCache.appendingPathComponent("objects/ab/file2"))
        #expect(GitService.directoryByteSize(at: tempCache) == 2_000)
    }

    @Test func lfsServiceStatusAndMutationsWithMockRunner() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let lfsCacheDir = fixture.root.appendingPathComponent(".git/lfs/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: lfsCacheDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 256).write(to: lfsCacheDir.appendingPathComponent("blob"))

        let mockRunner = MockLFSCommandRunner(root: fixture.root)
        let service = GitService(root: fixture.root, runner: mockRunner)

        let status = try await service.lfsStatus(includeLocks: true)
        #expect(status.availability == .available(version: "git-lfs/3.5.1 (GitHub; darwin arm64)"))
        #expect(status.patterns.count == 1)
        #expect(status.files.count == 1)
        #expect(status.locks.count == 1)
        #expect(status.locks[0].isOwnedByCurrentUser)
        #expect(status.cacheBytes == 256)

        try await service.lfsLock(path: "art/banner.psd")
        try await service.lfsUnlock(path: "art/banner.psd", force: true)

        let recorded = await mockRunner.recordedMutations
        #expect(recorded.contains { $0.contains("lock") && $0.contains("art/banner.psd") })
        #expect(recorded.contains { $0.contains("unlock") && $0.contains("--force") })

        await #expect(throws: GitError.self) {
            try await service.lfsLock(path: "../outside.psd")
        }
    }
}

private actor MockLFSCommandRunner: CommandRunning {
    let root: URL
    private(set) var recordedMutations: [[String]] = []

    init(root: URL) {
        self.root = root
    }

    func run(
        executable _: String,
        arguments: [String],
        directory _: URL?,
        timeout _: TimeInterval,
        outputLimit _: Int
    ) async throws -> CommandResult {
        handle(arguments)
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        handle(request.arguments)
    }

    private func handle(_ arguments: [String]) -> CommandResult {
        if arguments.contains("--show-toplevel") {
            return ok(root.path + "\n")
        }
        if arguments.contains("--absolute-git-dir") || arguments.contains("--git-common-dir") {
            return ok(root.appendingPathComponent(".git").path + "\n")
        }
        if let lfsIndex = arguments.firstIndex(of: "lfs"), lfsIndex + 1 < arguments.count {
            let subcommand = arguments[lfsIndex + 1]
            switch subcommand {
            case "version":
                return ok("git-lfs/3.5.1 (GitHub; darwin arm64)\n")
            case "track":
                return ok(
                    "Listing tracked patterns\n    *.psd (.gitattributes)\n"
                        + "Listing excluded patterns\n    *.tmp (.gitattributes)\n"
                )
            case "lock", "unlock":
                recordedMutations.append(arguments)
                return ok("")
            case "ls-files":
                let oid = String(repeating: "a", count: 64)
                return ok("\(oid) * art/banner.psd\n")
            case "locks":
                return ok(#"{"ours":[{"id":"7","path":"art/banner.psd","owner":{"name":"Jane"}}],"theirs":[]}"#)
            default:
                return ok("")
            }
        }
        return ok("")
    }

    private func ok(_ text: String) -> CommandResult {
        CommandResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
    }
}
