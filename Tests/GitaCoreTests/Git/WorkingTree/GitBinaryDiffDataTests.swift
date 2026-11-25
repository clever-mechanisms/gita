import Foundation
import Testing

@testable import GitaCore

@Suite("Binary diff payload loading", .serialized)
struct GitBinaryDiffDataTests {
    @Test func binaryObjectIDsParsesHeadersAndRejectsZeros() {
        let modified = """
            diff --git a/a.png b/a.png
            index 1234abc..5678def 100644
            Binary files a/a.png and b/a.png differ
            """
        let added = """
            diff --git a/a.png b/a.png
            new file mode 100644
            index 0000000..5678def
            Binary files /dev/null and b/a.png differ
            """
        let removed = """
            diff --git a/a.png b/a.png
            deleted file mode 100644
            index 1234abc..0000000
            Binary files a/a.png and /dev/null differ
            """
        #expect(GitService.binaryObjectIDs(in: modified) == ("1234abc", "5678def"))
        #expect(GitService.binaryObjectIDs(in: added) == (nil, "5678def"))
        #expect(GitService.binaryObjectIDs(in: removed) == ("1234abc", nil))
        #expect(GitService.binaryObjectIDs(in: "plain diff without index") == (nil, nil))
        #expect(GitService.binaryObjectIDs(in: "index nothex..1234abc") == (nil, "1234abc"))
    }

    @Test func binaryDiffDataResolvesUntrackedStagedUnstagedDeletedAndSizeLimits() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaBinaryDiff-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let service = GitService(root: root)
        let runner = CommandRunner()
        func git(_ args: [String]) async throws {
            let result = try await runner.run(
                executable: "git", arguments: args, directory: root, timeout: 10, outputLimit: 1_024 * 1_024)
            #expect(result.exitCode == 0)
        }
        try await git(["init", "--initial-branch=main"])
        try await git(["config", "user.name", "Gita Tests"])
        try await git(["config", "user.email", "tests@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])

        let fileURL = root.appendingPathComponent("img.png")
        let v1 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let v2 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x02, 0x03])
        let v3 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x04, 0x05, 0x06])

        // 1. Untracked added file reads new bytes from disk.
        try v1.write(to: fileURL)
        let untrackedDiff = try await service.diff(path: "img.png", tracking: .untracked)
        let untrackedPayload = await service.binaryDiffData(in: untrackedDiff, fileURL: fileURL, maxBytes: 1_024)
        #expect(untrackedPayload.oldData == nil)
        #expect(untrackedPayload.newData == v1)
        #expect(untrackedPayload.newByteCount == Int64(v1.count))

        // Size limit preserves byte count while skipping bytes.
        let cappedPayload = await service.binaryDiffData(in: untrackedDiff, fileURL: fileURL, maxBytes: 2)
        #expect(cappedPayload.newData == nil)
        #expect(cappedPayload.newByteCount == Int64(v1.count))

        // 2. Commit v1, stage v2, edit working tree to v3.
        try await service.stage(paths: ["img.png"])
        try await service.commit(message: "Add v1")
        try v2.write(to: fileURL)
        try await service.stage(paths: ["img.png"])
        try v3.write(to: fileURL)

        // Staged diff reads v1 -> v2 from Git object DB (ignoring v3 on disk).
        let stagedDiff = try await service.diff(path: "img.png", staged: true)
        let stagedPayload = await service.binaryDiffData(in: stagedDiff, fileURL: fileURL, maxBytes: 1_024)
        #expect(stagedPayload.oldData == v1)
        #expect(stagedPayload.newData == v2)
        #expect(stagedPayload.oldByteCount == Int64(v1.count))
        #expect(stagedPayload.newByteCount == Int64(v2.count))

        // Unstaged diff reads v2 from index object DB and v3 from disk.
        let unstagedDiff = try await service.diff(path: "img.png", staged: false, tracking: .tracked)
        let unstagedPayload = await service.binaryDiffData(in: unstagedDiff, fileURL: fileURL, maxBytes: 1_024)
        #expect(unstagedPayload.oldData == v2)
        #expect(unstagedPayload.newData == v3)

        // 3. Deleted file loads old bytes and never falls back to disk.
        try FileManager.default.removeItem(at: fileURL)
        let deletedDiff = try await service.diff(path: "img.png", staged: false, tracking: .tracked)
        let deletedPayload = await service.binaryDiffData(in: deletedDiff, fileURL: fileURL, maxBytes: 1_024)
        #expect(deletedPayload.oldData == v2)
        #expect(deletedPayload.newData == nil)

        // 4. Bounded commit blob read via fileData(commit:path:maxBytes:).
        let blobBytes = try await service.fileData(commit: "HEAD", path: "img.png", maxBytes: 1_024)
        #expect(blobBytes == v1)
    }
}
