import Foundation
import Testing
import os

@testable import GitaCore

@Suite("Git blame & incremental parser")
struct GitBlameTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaBlame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func git(
        _ root: URL, author: String = "Ada", email: String = "ada@example.com", _ args: [String]
    ) async throws -> CommandResult {
        let runner = CommandRunner()
        let result = try await runner.run(
            executable: "git",
            arguments: [
                "-c", "user.name=\(author)", "-c", "user.email=\(email)", "-c", "commit.gpgsign=false",
            ] + args,
            directory: root, timeout: 20, outputLimit: 2 * 1_024 * 1_024)
        #expect(result.exitCode == 0, "git \(args) failed: \(result.text)")
        return result
    }

    @Test func crlfBlamePreservesBlankLinesAndLineNumbers() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init"])
        try Data("first\r\n\r\nlast\r\n".utf8).write(to: root.appendingPathComponent("file"))
        _ = try await git(root, ["add", "file"])
        _ = try await git(root, ["commit", "-m", "CRLF"])
        let document = try await GitService(root: root).blame(path: "file")
        #expect(document.lines == ["first", "", "last"])
        #expect(document.annotations.allSatisfy { $0.commit != nil })
    }

    @Test func workingBlameRefusesSymlinkAndOversizedFile() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init"])
        let target = root.appendingPathComponent("target")
        try Data("content".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        let service = GitService(root: root)
        await #expect(throws: BlameError.unsupportedWorkingFile) { try await service.blameLines(path: "link") }
        let file = try FileHandle(forWritingTo: target)
        try file.truncate(atOffset: UInt64(GitService.blameOutputLimit + 1))
        try file.close()
        await #expect(throws: BlameError.unsupportedWorkingFile) { try await service.blameLines(path: "target") }
    }

    @Test func incrementalParserHandlesSplitChunksPreviousAndRepeatCommits() {
        let sha1 = String(repeating: "a", count: 40)
        let sha2 = String(repeating: "b", count: 40)
        let sample = """
            \(sha1) 1 1 2
            author Ada Lovelace
            author-mail <ada@example.com>
            author-time 1700000000
            author-tz +0000
            summary Initial
            boundary
            filename file.swift
            \(sha2) 3 3 1
            author Bob Builder
            author-mail <bob@example.com>
            author-time 1700005000
            author-tz +0000
            summary Update line 3
            previous \(sha1) old_file.swift
            filename file.swift
            \(sha1) 4 4 1
            filename file.swift

            """
        let data = Data(sample.utf8)
        let splitPoint = data.count / 2
        var parser = BlameIncrementalParser()
        let first = parser.feed(Data(data.prefix(splitPoint)))
        let second = parser.feed(Data(data.dropFirst(splitPoint)))
        let tail = parser.finish()

        let hunks = first.hunks + second.hunks + tail.hunks
        let commits = first.commits.merging(second.commits) { _, new in new }
            .merging(tail.commits) { _, new in new }

        #expect(hunks.count == 3)
        #expect(commits[sha1]?.isBoundary == true)
        #expect(commits[sha1]?.email == "ada@example.com")
        #expect(commits[sha2]?.author == "Bob Builder")
        #expect(hunks[1].previousCommit == sha1)
        #expect(hunks[1].previousPath == "old_file.swift")

        let doc = BlameDocument(
            path: "file.swift", revision: sha2,
            lines: ["line 1", "line 2", "line 3", "line 4"],
            commits: commits, hunks: hunks)
        #expect(doc.annotations.count == 4)
        #expect(doc.annotations[0].isBlockStart)
        #expect(!doc.annotations[1].isBlockStart)
        #expect(doc.annotations[2].isBlockStart)
        #expect(doc.annotations[3].isBlockStart)
        #expect(doc.heatLevel(for: Date(timeIntervalSince1970: 1_700_000_000)) == 0)
        #expect(doc.heatLevel(for: Date(timeIntervalSince1970: 1_700_005_000)) == 2)
        #expect(doc.blockRange(at: 0) == 0..<2)
        #expect(doc.priorRevision(at: 2)?.commit == sha1)
        #expect(doc.priorRevision(at: 2)?.path == "old_file.swift")
        #expect(doc.priorRevision(at: 0) == nil)
    }

    @Test func streamingBlameOnFixtureRepoTracksAuthorsAndIgnoresRevsFile() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init", "--initial-branch=main", "--template="])
        let file = root.appendingPathComponent("code.swift")
        try "let a = 1\nlet b = 2\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "code.swift"])
        _ = try await git(root, author: "Ada", email: "ada@example.com", ["commit", "-m", "Add a and b"])

        try "let a = 1\nlet b = 20\nlet c = 3\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "code.swift"])
        _ = try await git(root, author: "Bob", email: "bob@example.com", ["commit", "-m", "Edit b and add c"])
        let bobSHA = GitOutput.withoutTerminalLF(
            try await git(root, ["rev-parse", "HEAD"]).text)

        let service = GitService(root: root)
        let progressCount = OSAllocatedUnfairLock(initialState: 0)
        let doc = try await service.blame(path: "code.swift", revision: "HEAD") { _ in
            progressCount.withLock { $0 += 1 }
        }
        #expect(progressCount.withLock { $0 } >= 1)
        #expect(doc.lines == ["let a = 1", "let b = 20", "let c = 3"])
        #expect(doc.annotations[0].commit?.author == "Ada")
        #expect(doc.annotations[1].commit?.author == "Bob")
        #expect(doc.annotations[2].commit?.author == "Bob")
        #expect(doc.priorRevision(at: 1)?.commit != nil)

        // Configure blame.ignoreRevsFile to ignore Bob's commit; blame should honor it automatically.
        let ignoreFile = root.appendingPathComponent(".git-blame-ignore-revs")
        try "\(bobSHA)\n".write(to: ignoreFile, atomically: true, encoding: .utf8)
        _ = try await git(root, ["config", "blame.ignoreRevsFile", ".git-blame-ignore-revs"])
        let ignoredDoc = try await service.blame(path: "code.swift", revision: "HEAD")
        #expect(ignoredDoc.annotations[1].commit?.author == "Ada")

        // Working-tree blame marks uncommitted lines cleanly.
        try "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n".write(to: file, atomically: true, encoding: .utf8)
        let workingDoc = try await service.blame(path: "code.swift", revision: nil)
        #expect(workingDoc.annotations[3].commit?.isUncommitted == true)
    }

    @Test func blameRejectsBinaryFileAndSurfacesFailures() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await git(root, ["init", "--initial-branch=main", "--template="])
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: root.appendingPathComponent("image.bin"))
        _ = try await git(root, ["add", "image.bin"])
        _ = try await git(root, ["commit", "-m", "Binary"])

        let service = GitService(root: root)
        await #expect(throws: BlameError.binaryFile) {
            try await service.blame(path: "image.bin", revision: "HEAD")
        }
    }
}
