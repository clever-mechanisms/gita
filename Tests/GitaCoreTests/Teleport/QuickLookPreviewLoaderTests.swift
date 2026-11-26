import Foundation
import Testing

@testable import GitaCore

struct QuickLookPreviewLoaderTests {
    private let sha = String(repeating: "c", count: 40)
    private let root = URL(filePath: "/tmp/preview-loader")

    private var runner: DetailRecordingRunner {
        DetailRecordingRunner { [sha, root] call in
            let args = call.arguments
            let output: String
            var exit: Int32 = 0
            if args.contains("--show-toplevel") {
                output = root.path + "\n"
            } else if args.contains("config") || args.contains(sha + "^3") {
                output = ""
                exit = 1
            } else if args.contains("rev-parse") {
                output = sha + "\n"
            } else if args.contains("--no-patch") {
                output = [sha, "", "Mina", "", "100", "", "Preview subject", ""].joined(separator: "\0")
            } else if args.contains("--shortstat") {
                output = " 2 files changed, 1 insertion(+)\n"
            } else if args.contains("--name-status") {
                output = "A\0a.swift\0M\0b.swift\0"
            } else if args.contains("--cached") {
                #expect(args.suffix(2) == ["--", "image file"])
                output = "diff --git a/image b/image\nBinary files a/image and b/image differ\n"
            } else if args.contains("show") {
                output = "@@ -1 +1 @@\n-old\n+new\n"
            } else {
                throw CommandError.invalidArgument
            }
            return .init(stdout: Data(output.utf8), stderr: Data(), exitCode: exit)
        }
    }

    @Test func commitsAndStashes() async throws {
        let loader = QuickLookPreviewLoader(runner: runner, maxLines: 2, maxFiles: 1)
        let hint = CommitHint(prTitle: "Review", prState: .success, ciState: .running)
        let commit = QuickLookTarget.commit(repoPath: root, sha: sha, metadata: hint)
        let stash = QuickLookTarget.stash(repoPath: root, ref: "stash@{0}", message: nil)
        for target in [commit, stash] {
            let preview = try await loader.load(target)
            #expect(preview.target == target && preview.commitSHA == sha)
            #expect(preview.title == "Preview subject" && preview.author == "Mina")
            #expect(preview.date == Date(timeIntervalSince1970: 100))
            #expect(preview.files.map(\.path) == ["a.swift"] && preview.omittedFileCount == 1)
            #expect(preview.statSummary == "2 files changed, 1 insertion(+)")
            #expect(preview.diffExcerpt.lines == ["@@ -1 +1 @@", "-old"] && preview.diffExcerpt.isTruncated)
            if target == commit { #expect(preview.pills.map(\.state) == [.success, .running]) }
        }
    }

    @Test func binaryStagedFile() async throws {
        let target = QuickLookTarget.changedFile(repoPath: root, path: "image file", staged: true, statusCode: .added)
        let content = try await QuickLookPreviewLoader(runner: runner).load(target)
        #expect(QuickLookLoadState.loaded(content).target == target)
        #expect(content.isBinary && content.diffExcerpt.totalLineCount == 2)
        #expect(content.pills.map(\.title) == ["Added"] && content.subtitle == "Staged")
    }

    @Test func targetThroughoutLoadingLifecycle() {
        let target = QuickLookTarget.commit(repoPath: root, sha: sha)
        #expect(QuickLookLoadState.idle.target == nil)
        for state: QuickLookLoadState in [
            .loading(target, showsSpinner: false), .loading(target, showsSpinner: true),
            .empty(target, "No changes"), .failed(target, "Unavailable"),
        ] {
            #expect(state.target == target)
        }
    }

    @Test func truncationPreservesCompleteUTF8Lines() {
        let text = "é\r\n\n日\nlast"
        let excerpt = QuickLookPreviewLoader.truncateDiff(text, maxLines: 10, maxBytes: 7)
        #expect(excerpt.lines == ["é", ""] && excerpt.isTruncated)
        #expect(excerpt.totalLineCount == 4 && excerpt.totalByteCount == text.utf8.count)
        let full = QuickLookPreviewLoader.truncateDiff(text, maxLines: 4, maxBytes: text.utf8.count)
        #expect(full.lines == ["é", "", "日", "last"] && !full.isTruncated)
        #expect(QuickLookPreviewLoader.truncateDiff(text, maxLines: -1, maxBytes: 0).lines.isEmpty)
        #expect(QuickLookPreviewLoader.truncateDiff("", maxLines: 0, maxBytes: 0).totalLineCount == 0)
        #expect(QuickLookPreviewLoader.truncateDiff("+é\n", maxLines: 1, maxBytes: 2).lines.isEmpty)
    }

    @Test func cancellationStopsBeforeGit() async {
        let runner = self.runner
        let target = QuickLookTarget.commit(repoPath: root, sha: sha)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await QuickLookPreviewLoader(runner: runner).load(target)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await runner.calls.isEmpty)
    }
}
