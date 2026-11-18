import Foundation
import Testing

@testable import GitaCore

private struct DiffRepository {
    let root: URL
    let runner = CommandRunner()

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaDiffTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch=main"])
        try await git(["config", "user.name", "Diff Tests"])
        try await git(["config", "user.email", "diff@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", "/dev/null"])
        try await git(["config", "core.autocrlf", "false"])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ value: String, path: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent(path))
    }
    @discardableResult func git(_ arguments: [String]) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: ["--literal-pathspecs", "-c", "core.quotepath=false"] + arguments,
            directory: root, timeout: 10, outputLimit: 8 * 1_024 * 1_024)
        guard result.exitCode == 0 else { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }
    func seed(_ value: String, path: String) async throws {
        try write(value, path: path)
        try await git(["add", "--", path])
        try await git(["commit", "-m", "Seed diff fixture"])
    }
    func diff(path: String) async throws -> String {
        try await git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", path]).text
    }
    func apply(_ patch: String, reverse: Bool = false) async throws {
        let url = root.appendingPathComponent("patch-" + UUID().uuidString)
        try Data(patch.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let args = ["apply", "--cached"] + (reverse ? ["--reverse"] : [])
        try await git(args + ["--check", "--", url.path])
        try await git(args + ["--", url.path])
    }
    func indexed(_ path: String) async throws -> String { try await git(["show", ":" + path]).text }
}

struct UnifiedDiffTests {
    private static let prefix =
        "diff --git a/file.txt b/file.txt\nindex 1111111..2222222 100644\n--- a/file.txt\n+++ b/file.txt\n"
    private static let simpleHunk = "@@ -1 +1 @@\n-before\n+after\n"

    @Test func contentLookingLikeFileHeadersKeepsItsLineNumbersAndHunk() {
        let text = Self.prefix + "@@ -8,3 +8,3 @@ function\n context\n--- left\n+++ right\n end\n"
        let document = UnifiedDiff.parse(text)
        #expect(document.canApplyHunks)
        #expect(document.hunks.count == 1)
        #expect(document.hunks[0].patch == text)
        #expect(document.lines.indices.filter { document.lines[$0].hunkIndex == 0 } == Array(4..<9))
        #expect(document.lines[6].text == "--- left")
        #expect(document.lines[6].old == "9" && document.lines[6].new.isEmpty && document.lines[6].kind == "-")
        #expect(document.lines[7].new == "9" && document.lines[7].old.isEmpty && document.lines[7].kind == "+")
        #expect(document.lines[8].old == "10" && document.lines[8].new == "10")
        #expect(document.lines[4...].allSatisfy { $0.hunkIndex == 0 })
        #expect(document.lines[..<4].allSatisfy { $0.hunkIndex == nil })
    }

    @Test func gitGeneratedLaterHunkAppliesIndependentlyAndReversesWithoutTouchingWorktree() async throws {
        let repository = try await DiffRepository()
        defer { repository.remove() }
        let original = (1...80).map { "line \($0)\n" }.joined()
        let modified = original.replacingOccurrences(
            of: "line 2\n", with: "first insertion\nsecond insertion\nline 2\n"
        )
        .replacingOccurrences(of: "line 60\n", with: "changed 60\n")
        try await repository.seed(original, path: "file.txt")
        try repository.write(modified, path: "file.txt")
        let document = UnifiedDiff.parse(try await repository.diff(path: "file.txt"))
        try #require(document.canApplyHunks && document.hunks.count == 2)
        try await repository.apply(document.hunks[1].patch)
        #expect(
            try await repository.indexed("file.txt")
                == original.replacingOccurrences(of: "line 60\n", with: "changed 60\n"))
        #expect(try String(contentsOf: repository.root.appendingPathComponent("file.txt"), encoding: .utf8) == modified)
        try await repository.git(["add", "--", "file.txt"])
        try await repository.apply(document.hunks[1].patch, reverse: true)
        #expect(
            try await repository.indexed("file.txt")
                == modified.replacingOccurrences(of: "changed 60\n", with: "line 60\n"))
        #expect(try String(contentsOf: repository.root.appendingPathComponent("file.txt"), encoding: .utf8) == modified)
    }

    @Test func gitGeneratedNoNewlineMarkersStayWithTheirHunkAndDoNotAdvanceNumbers() async throws {
        let repository = try await DiffRepository()
        defer { repository.remove() }
        let original = (1...30).map { "line \($0)\n" }.joined() + "old ending"
        let modified = original.replacingOccurrences(of: "line 2\n", with: "changed beginning\n")
            .replacingOccurrences(of: "old ending", with: "new ending")
        try await repository.seed(original, path: "file.txt")
        try repository.write(modified, path: "file.txt")
        let document = UnifiedDiff.parse(try await repository.diff(path: "file.txt"))
        try #require(document.canApplyHunks && document.hunks.count == 2)
        let markers = document.lines.filter { $0.text == "\\ No newline at end of file" }
        #expect(markers.count == 2)
        #expect(markers.allSatisfy { $0.old.isEmpty && $0.new.isEmpty && $0.hunkIndex == 1 && $0.kind == "h" })
        try await repository.apply(document.hunks[1].patch)
        #expect(
            try await repository.indexed("file.txt")
                == original.replacingOccurrences(of: "old ending", with: "new ending"))
    }

    @Test func gitGeneratedCRLFAndQuotedPathsRoundTripWithoutChangingPatchBytes() async throws {
        let repository = try await DiffRepository()
        defer { repository.remove() }
        for path in ["spaces in name.txt", "tabs\tnewlines\nquotes\"backslash\\.txt", "café-雪.txt"] {
            let original = "first\r\n-- old\r\nlast\r\n"
            let modified = "first\r\n++ new\r\nlast\r\n"
            try await repository.seed(original, path: path)
            try repository.write(modified, path: path)
            let raw = try await repository.diff(path: path)
            let document = UnifiedDiff.parse(raw)
            try #require(
                document.canApplyHunks && document.hunks.count == 1,
                "Unsupported Git-generated path: \(path.debugDescription)\n\(raw)")
            #expect(document.hunks[0].patch == raw)
            #expect(document.lines.contains { $0.text == "--- old\r" && $0.old == "2" && $0.kind == "-" })
            #expect(document.lines.contains { $0.text == "+++ new\r" && $0.new == "2" && $0.kind == "+" })
            try await repository.apply(document.hunks[0].patch)
            #expect(try await repository.indexed(path) == modified)
        }
    }

    @Test func gitGeneratedOctalUnicodeFilenameEscapesAreDecodedWithoutOverflow() async throws {
        let repository = try await DiffRepository()
        defer { repository.remove() }
        let path = "café-雪.txt"
        try await repository.seed("before\n", path: path)
        try repository.write("after\n", path: path)
        let text = try await repository.git([
            "-c", "core.quotepath=true", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--", path,
        ]).text
        #expect(text.contains("\\351"))
        let document = UnifiedDiff.parse(text)
        try #require(document.canApplyHunks && document.hunks.count == 1)
        #expect(document.hunks[0].patch == text)
        try await repository.apply(document.hunks[0].patch)
        #expect(try await repository.indexed(path) == "after\n")
    }

    @Test func unsupportedOrMalformedPatchesRemainDisplayableButNeverProduceApplicableHunks() {
        let ordinary = Self.prefix + Self.simpleHunk
        let invalid = [
            "",
            ordinary + ordinary,
            ordinary.replacingOccurrences(of: "diff --git", with: "diff --cc"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@@ -1,1 -1,1 +1,1 @@@"),
            ordinary.replacingOccurrences(of: "index ", with: "old mode 100644\nnew mode 100755\nindex "),
            ordinary.replacingOccurrences(
                of: "index ", with: "similarity index 90%\nrename from old.txt\nrename to file.txt\nindex "),
            ordinary.replacingOccurrences(of: "100644", with: "160000"),
            ordinary.replacingOccurrences(of: "100644", with: "120000"),
            ordinary.replacingOccurrences(of: " 100644", with: ""),
            ordinary.replacingOccurrences(of: "2222222", with: "0000000"),
            ordinary.replacingOccurrences(of: "+++ b/file.txt", with: "+++ /dev/null"),
            ordinary.replacingOccurrences(of: "+++ b/file.txt", with: "+++ b/other.txt"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -1,2 +1 @@"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -0 +1 @@"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -1 +20 @@"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -999999999999999999999 +1 @@"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -\(Int.max) +1 @@"),
            ordinary.replacingOccurrences(of: "@@ -1 +1 @@", with: "@@ -1 +1 @@garbage"),
            ordinary + "+extra\n",
            ordinary + "@@ -10 +11 @@\n-before\n+after\n",
            ordinary + "unexpected trailer\n",
            ordinary + "\\ No newline at end of file\n\\ No newline at end of file\n",
            ordinary + "\\ No newline at end of file\n@@ -10 +10 @@\n-before\n+after\n",
            Self.prefix + "@@ -1,2 +1,2 @@\n-old\n\\ No newline at end of file\n+new\n context\n",
            String(ordinary.dropLast()),
            Self.prefix + "Binary files a/file.txt and b/file.txt differ\n",
            Self.prefix + "GIT binary patch\nliteral 3\nabc\n",
            ordinary.replacingOccurrences(of: "file.txt", with: "../file.txt"),
        ]
        for text in invalid {
            let document = UnifiedDiff.parse(text)
            #expect(!document.canApplyHunks, "Unexpected eligible patch: \(text)")
            #expect(document.hunks.allSatisfy { $0.patch.isEmpty })
            #expect(text.isEmpty || !document.lines.isEmpty)
        }
    }

    @Test func zeroLengthRangesAndExecutableFilesAreSupportedWithoutTreatingThemAsFileDeletion() {
        for hunk in ["@@ -0,0 +1 @@\n+first line\n", "@@ -1 +0,0 @@\n-last line\n"] {
            let text = Self.prefix.replacingOccurrences(of: "100644", with: "100755") + hunk
            let document = UnifiedDiff.parse(text)
            #expect(document.canApplyHunks)
            #expect(document.hunks.first?.patch == text)
        }
    }

    @Test func repeatedLongHeadersCannotAmplifyPatchMemoryQuadratically() {
        let name = String(repeating: "x", count: 4_096)
        let prefix = Self.prefix.replacingOccurrences(of: "file.txt", with: name)
        let hunks = (1...300).map { "@@ -\($0 * 10) +\($0 * 10) @@\n-before\n+after\n" }.joined()
        let document = UnifiedDiff.parse(prefix + hunks)
        #expect(!document.canApplyHunks)
        #expect(document.hunks.count == 300)
        #expect(document.hunks.allSatisfy { $0.patch.isEmpty })
    }

    @Test func normalLongFilenameAndSeveralSmallHunksStillProducePatches() {
        let prefix = Self.prefix.replacingOccurrences(of: "file.txt", with: String(repeating: "name", count: 30))
        let hunks = (1...20).map { "@@ -\($0 * 10) +\($0 * 10) @@\n-before\n+after\n" }.joined()
        let document = UnifiedDiff.parse(prefix + hunks)
        #expect(document.canApplyHunks)
        #expect(document.hunks.count == 20)
        #expect(document.hunks.allSatisfy { $0.patch.hasPrefix(prefix) })
    }

    @Test func canonicallyEquivalentButDifferentFilenameBytesDoNotMatchHeaders() {
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let metadata =
            "diff --git a/\(decomposed) b/\(decomposed)\nindex 1111111..2222222 100644\n--- a/\(composed)\n+++ b/\(composed)\n"
        let document = UnifiedDiff.parse(metadata + Self.simpleHunk)
        #expect(!document.canApplyHunks)
        #expect(document.hunks.allSatisfy { $0.patch.isEmpty })
    }

    @Test func gitGeneratedFinalNewlineTransitionsAndUnterminatedContextApplyAndReverse() async throws {
        let repository = try await DiffRepository()
        defer { repository.remove() }
        let scenarios = [("old", "new\n"), ("old\n", "new"), ("old\nlast", "new\nlast")]
        for (index, scenario) in scenarios.enumerated() {
            let path = "ending-\(index).txt"
            try await repository.seed(scenario.0, path: path)
            try repository.write(scenario.1, path: path)
            let document = UnifiedDiff.parse(try await repository.diff(path: path))
            try #require(document.canApplyHunks && document.hunks.count == 1)
            try await repository.apply(document.hunks[0].patch)
            #expect(try await repository.indexed(path) == scenario.1)
            try await repository.apply(document.hunks[0].patch, reverse: true)
            #expect(try await repository.indexed(path) == scenario.0)
        }
    }

    @Test func largeTextParsingKeepsAllContentAndRunsInPredictableTime() {
        let count = ProcessInfo.processInfo.environment["GITA_BENCHMARK"] == "1" ? 100_000 : 20_000
        let body = (1...count).map { " line \($0) · Unicode 雪\n" }.joined()
        let text = Self.prefix + "@@ -1,\(count + 1) +1,\(count + 1) @@\n-old\n+new\n" + body
        let start = ContinuousClock.now
        let document = UnifiedDiff.parse(text)
        let elapsed = start.duration(to: .now)
        #expect(document.canApplyHunks)
        #expect(document.lines.count == count + 7)
        #expect(document.lines.last?.old == String(count + 1))
        #expect(document.hunks.first?.patch == text)
        #expect(elapsed < .seconds(15))
        let milliseconds =
            Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        print("GITA_DIFF_BENCHMARK lines=\(count) bytes=\(text.utf8.count) milliseconds=\(milliseconds)")
    }
}
