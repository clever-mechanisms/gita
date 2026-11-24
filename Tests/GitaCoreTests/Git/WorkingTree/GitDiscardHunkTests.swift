import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitDiscardHunkTests {
    @Test func discardHunkRevertsSelectedHunkAndKeepsOtherHunkAndIndex() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let baseline = (1...35).map { "Line \($0)\n" }.joined()
        try fixture.write("lines.txt", baseline)
        try await fixture.commit("Baseline")

        // Stage an edit on line 15, then make two separate unstaged hunks at lines 2 and 30.
        let staged = baseline.replacingOccurrences(of: "Line 15\n", with: "Staged 15\n")
        try fixture.write("lines.txt", staged)
        try await fixture.service.stage(paths: ["lines.txt"])

        let working =
            staged
            .replacingOccurrences(of: "Line 2\n", with: "Unstaged 2\n")
            .replacingOccurrences(of: "Line 30\n", with: "Unstaged 30\n")
        try fixture.write("lines.txt", working)

        let expectedDiff = try await fixture.service.diff(path: "lines.txt", staged: false)
        try await fixture.service.discardHunk(path: "lines.txt", expectedDiff: expectedDiff, hunkIndex: 0)

        let onDisk = try String(contentsOf: fixture.root.appendingPathComponent("lines.txt"), encoding: .utf8)
        #expect(onDisk.contains("Line 2\n"))
        #expect(!onDisk.contains("Unstaged 2\n"))
        #expect(onDisk.contains("Staged 15\n"))
        #expect(onDisk.contains("Unstaged 30\n"))
        let indexContent = try await fixture.git(["show", ":lines.txt"]).text
        #expect(indexContent == staged)
    }

    @Test func discardHunkRejectsStaleDiffOnByteMismatch() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "one\ntwo\n")
        try await fixture.commit("Initial")

        try fixture.write("file.txt", "one\nchanged\n")
        let expectedDiff = try await fixture.service.diff(path: "file.txt", staged: false)
        try fixture.write("file.txt", "one\nchanged again\n")

        await expectGitError(.staleDiff) {
            try await fixture.service.discardHunk(path: "file.txt", expectedDiff: expectedDiff, hunkIndex: 0)
        }
        let onDisk = try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(onDisk == "one\nchanged again\n")
    }

    @Test func discardHunkRejectsUntrackedInvalidPathAndOutOfRangeHunk() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "a\nb\n")
        try await fixture.commit("Initial")

        try fixture.write("untracked.txt", "hello\n")
        let untrackedDiff = try await fixture.service.diff(path: "untracked.txt", staged: false)
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.discardHunk(path: "untracked.txt", expectedDiff: untrackedDiff, hunkIndex: 0)
        }

        try fixture.write("tracked.txt", "a\nc\n")
        let trackedDiff = try await fixture.service.diff(path: "tracked.txt", staged: false)
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.discardHunk(path: "tracked.txt", expectedDiff: trackedDiff, hunkIndex: 99)
        }

        await expectGitError(.invalidPath) {
            try await fixture.service.discardHunk(path: "../escape.txt", expectedDiff: trackedDiff, hunkIndex: 0)
        }

        let oversized = String(repeating: "x", count: GitService.hunkDiffLimit + 1)
        await expectError(CommandError.outputLimitExceeded(GitService.hunkDiffLimit)) {
            try await fixture.service.discardHunk(path: "tracked.txt", expectedDiff: oversized, hunkIndex: 0)
        }
    }
}
