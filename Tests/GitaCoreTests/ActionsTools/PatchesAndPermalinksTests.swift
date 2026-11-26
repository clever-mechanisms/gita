import Foundation
import Testing

@testable import GitaCore

@Suite struct ActionsToolsPatchesAndPermalinksTests {
    @Test func exportsAllSourcesAndAppliesBinaryWithNoPrefixConfig() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try await repo.git(["config", "diff.noprefix", "true"])
        try await repo.git(["config", "diff.submodule", "diff"])
        let file = "with space\tand newline\n.txt"
        try repo.write(file, "old\n")
        try repo.write("photo.bin", data: Data([0, 1, 2]))
        let base = try await repo.commit("First")
        await #expect(throws: PatchError.emptyPatch) { try await repo.service.exportPatch(.workingTree) }
        try repo.write(file, "new\nanother\n")
        try repo.write("photo.bin", data: Data([0, 2, 3]))
        let working = try await repo.service.exportPatch(.workingTree)
        let workingText = String(decoding: working, as: UTF8.self)
        #expect(workingText.contains("a/photo.bin") && workingText.contains("b/photo.bin"))
        try await repo.git(["add", "--all"])
        #expect(try await repo.service.exportPatch(.staged) == working)
        let next = try await repo.commit("Second")
        let commit = try await repo.service.exportPatch(.commit(sha: next))
        #expect(String(decoding: commit, as: UTF8.self).contains("Subject: [PATCH] Second"))
        #expect(try await repo.service.exportPatch(.commitRange(from: base, to: next)) == commit)
        try await repo.git(["switch", "--detach", base])
        let patch = repo.container.appending(path: "-example.patch")
        try working.write(to: patch)
        let preview = try await repo.service.checkPatch(at: patch)
        #expect(preview.files.count == 2 && preview.canApplyCleanly)
        #expect(preview.totalAdditions == 2 && preview.totalDeletions == 1)
        #expect(preview.files.contains(where: { $0.isBinary && $0.path == "photo.bin" }))
        #expect(preview.files.contains(where: { $0.path == file }))
        try await repo.service.applyPatch(preview, options: PatchApplyOptions(index: true))
        #expect(try await repo.service.exportPatch(.staged) == working)
        #expect(try Data(contentsOf: repo.root.appending(path: "photo.bin")) == Data([0, 2, 3]))
    }

    @Test func threeWayRecoversFromContextMismatch() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let base = "one\ntwo\nthree\nfour\nfive\n"
        try repo.write("text", base)
        try await repo.commit("Base")
        try repo.write("text", base.replacingOccurrences(of: "one", with: "ONE"))
        let patch = repo.container.appending(path: "change.patch")
        try await repo.service.exportPatch(.workingTree).write(to: patch)
        try repo.write("text", base.replacingOccurrences(of: "four", with: "FOUR"))
        try await repo.commit("Updated context")
        let check = try await repo.service.checkPatch(at: patch)
        #expect(!check.canApplyCleanly && check.canApplyWithThreeWay && check.diagnostic != nil)
        let merged = try await repo.service.checkPatch(at: patch, threeWay: true)
        #expect(merged.canApplyWithThreeWay && merged.diagnostic == nil)
        #expect(try await repo.git(["status", "--porcelain"]).text.isEmpty)
        try await repo.service.applyPatch(merged, options: PatchApplyOptions(threeWay: true))
        let result = try String(contentsOf: repo.root.appending(path: "text"), encoding: .utf8)
        #expect(result == "ONE\ntwo\nthree\nFOUR\nfive\n")
    }

    @Test func unresolvedThreeWayConflictStaysBlocked() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let tips = try await repo.diverge()
        let file = repo.container.appending(path: "conflicting.patch")
        try await repo.service.exportPatch(.commit(sha: tips.incoming)).write(to: file)
        let preview = try await repo.service.checkPatch(at: file, threeWay: true)
        #expect(!preview.canApplyCleanly && !preview.canApplyWithThreeWay)
        #expect(!PatchApplyState.ready(preview).canApply(threeWay: true) && preview.diagnostic != nil)
        #expect(try await repo.git(["status", "--porcelain"]).text.isEmpty)
    }

    @Test func replacementAfterReviewCannotChangeTheAppliedPatch() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("file", "base\n")
        try await repo.commit("Base")
        try repo.write("file", "first edit\n")
        let first = try await repo.service.exportPatch(.workingTree)
        try repo.write("file", "replacement edit\n")
        let replacement = try await repo.service.exportPatch(.workingTree)
        try await repo.git(["restore", "--", "file"])
        let file = repo.container.appending(path: "changes.patch")
        try first.write(to: file)
        let preview = try await repo.service.checkPatch(at: file)
        try replacement.write(to: file, options: .atomic)
        await #expect(throws: PatchError.changedSincePreview) { try await repo.service.applyPatch(preview) }
        #expect(try await repo.git(["status", "--porcelain"]).text.isEmpty)
        try first.write(to: file)
        try await repo.service.applyPatch(preview)
        #expect(try await repo.service.exportPatch(.workingTree) == first)
    }

    @Test func refusesUnreadableAndOversizedInputs() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        let large = repo.container.appending(path: "large")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024 + 1)
        try handle.close()
        await #expect(throws: PatchError.fileTooLarge) { try await repo.service.checkPatch(at: large) }
        await #expect(throws: PatchError.invalidFile) { try await repo.service.checkPatch(at: repo.root) }
        await #expect(throws: PatchError.invalidFile) {
            try await repo.service.checkPatch(at: repo.root.appending(path: "missing"))
        }
    }

    @Test func providerPermalinks() {
        let providers = [
            ("git@github.com-work:team/repo.git", "github.com/team/repo", "commit", "blob", "L10-L20"),
            ("http://github.company/team/repo.git", "github.company/team/repo", "commit", "blob", "L10-L20"),
            ("ssh://git@gitlab.company:2222/a/b/c.git", "gitlab.company/a/b/c", "-/commit", "-/blob", "L10-20"),
            ("https://gitlab.com/a/b.git", "gitlab.com/a/b", "-/commit", "-/blob", "L10-20"),
            ("git@bitbucket.org:a/b.git", "bitbucket.org/a/b", "commits", "src", "lines-10:20"),
        ]
        for (remote, root, commit, file, anchor) in providers {
            #expect(
                RemotePermalinkBuilder.commitURL(remote: remote, sha: "abcd")?.absoluteString
                    == "https://\(root)/\(commit)/abcd")
            let ranged = RemotePermalinkBuilder.fileURL(
                remote: remote, ref: "feature/a", path: "src/a #?%.txt",
                lines: 10...20)
            #expect(ranged?.absoluteString == "https://\(root)/\(file)/feature%2Fa/src/a%20%23%3F%25.txt#\(anchor)")
            let single = RemotePermalinkBuilder.fileURL(remote: remote, ref: "abc", path: "README", lines: 10...10)
            #expect(single?.fragment == (root.hasPrefix("bitbucket") ? "lines-10" : "L10"))
        }
    }

    @Test func rejectsInvalidPermalinks() {
        let remote = "https://github.com/a/b"
        for invalid in [
            "/local", "file:///repo", "https://example.org/a/b", "https://github.com/a//b",
            "https://github.com/a/%2E%2E/b", "https://github.com/a/%00b",
        ] {
            #expect(RemotePermalinkBuilder.commitURL(remote: invalid, sha: "abc") == nil)
        }
        for path in ["", "/a", "a//b", "../b", "a/../b", "a\nb"] {
            #expect(RemotePermalinkBuilder.fileURL(remote: remote, ref: "main", path: path) == nil)
        }
        #expect(RemotePermalinkBuilder.fileURL(remote: remote, ref: "..", path: "a") == nil)
        #expect(RemotePermalinkBuilder.fileURL(remote: remote, ref: "main", path: "a", lines: 0...1) == nil)
    }
}
